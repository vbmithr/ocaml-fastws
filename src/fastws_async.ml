(*---------------------------------------------------------------------------
   Copyright (c) 2020 DeepMarker. All rights reserved.
   Distributed under the ISC license, see terms at the end of the file.
  ---------------------------------------------------------------------------*)

open Core
open Async
open Fastws
open Fastws_async_raw

let src = Logs.Src.create "fastws.async"

module Log = (val Logs.src_log src : Logs.LOG)

module Log_async = (val Logs_async.src_log src : Logs_async.LOG)

let empty_payload = Bigstring.create 0

type st = {
  buf : Bigbuffer.t;
  monitor : Monitor.t;
  mutable header : Header.t list;
  mutable conn_state : [ `Open | `Closing | `Closed ];
  on_pong : Time_ns.Span.t option -> unit;
}

let pp ppf st =
  Format.fprintf ppf "st[%a '%s']"
    (Format.pp_print_list ~pp_sep:Format.pp_print_space Header.pp)
    st.header
    (Bigbuffer.contents st.buf)

let create_st ?(on_pong = Fn.ignore) () =
  {
    buf = Bigbuffer.create 13;
    monitor = Monitor.create ();
    header = [];
    conn_state = `Open;
    on_pong;
  }

let reassemble st t =
  let return_buffer ?b h t =
    st.header <- t;
    Option.iter b ~f:(Bigbuffer.add_bigstring st.buf);
    let payload = Bigbuffer.big_contents st.buf in
    let length = Bigstring.length payload in
    Bigbuffer.clear st.buf;
    Ok (`Frame { Frame.header = { h with length }; payload })
  in
  match (t, st.header) with
  (* Payload cases: eats a header *)
  | Payload _, [] ->
      Format.kasprintf Or_error.error_string "payload without a header"
  | Payload b, h :: t -> (
      match (h.final, t) with
      | true, [] ->
          return_buffer ~b h t
          (* st.header <- t;
           * Bigbuffer.add_bigstring st.buf b;
           * let payload = Bigbuffer.big_contents st.buf in
           * let length = Bigstring.length payload in
           * Bigbuffer.clear st.buf;
           * Ok (`Frame { Frame.header = { h with length }; payload }) *)
      | false, [] ->
          Bigbuffer.add_bigstring st.buf b;
          Ok `Continue
      | true, _ ->
          st.header <- t;
          Ok (`Frame { Frame.header = h; payload = b })
      | false, _ -> assert false )
  (* Erroneous header cases *)
  | Header { opcode; final = false; _ }, _ when Opcode.is_control opcode ->
      Format.kasprintf Or_error.error_string "fragmented control frame"
  | Header { opcode; final = true; _ }, { final = false; _ } :: _
    when not Opcode.(is_control opcode || is_continuation opcode) ->
      Format.kasprintf Or_error.error_string "unfinished continuation"
  (* Valid header cases *)
  | Header ({ opcode = Continuation; final; length; _ } as ch), _ -> (
      match st.header with
      | [] -> Format.kasprintf Or_error.error_string "orphan continuation frame"
      | h :: t ->
          if final && length = 0 then return_buffer { h with final = true } t
          else (
            st.header <- { ch with opcode = h.opcode } :: t;
            Ok `Continue ) )
  | Header ({ length = 0; final = true; _ } as h), [] ->
      Ok (`Frame { Frame.header = h; payload = empty_payload })
  | Header ({ opcode; length = 0; _ } as h), _ :: _
    when Opcode.is_control opcode ->
      Ok (`Frame { Frame.header = h; payload = empty_payload })
  | Header h, _ ->
      st.header <- h :: st.header;
      Ok `Continue

let r3_of_r2 st ({ Frame.header; payload } as frame) =
  match header.opcode with
  | _ when Opcode.is_control header.opcode && Bigstring.length payload >= 126 ->
      Error (Some (Status.ProtocolError, "control frame too big"))
  | Ping -> Ok (Some { frame with header = { header with opcode = Pong } }, None)
  | Close ->
      let status =
        Option.value ~default:Status.NormalClosure (Status.of_payload payload)
      in
      Log.debug (fun m ->
          m "Remote endpoint closed connection (%a)" Status.pp status);
      Error None
  | Pong -> (
      match Bigstringaf.length payload with
      | 0 ->
          st.on_pong None;
          Log.info (fun m -> m "got pong with no payload");
          Ok (None, None)
      | _ ->
          Log.info (fun m -> m "got unsollicited pong with payload");
          ( try
              let now = Time_ns.now () in
              let old = Time_ns.of_string (Bigstring.to_string payload) in
              let diff = Time_ns.diff now old in
              Log.debug (fun m -> m "<- PONG %a" Time_ns.Span.pp diff);
              st.on_pong (Some diff)
            with _ -> () );
          Ok (None, None) )
  | Text | Binary -> Ok (None, Some frame)
  | Continuation -> assert false
  | Ctrl _ | Nonctrl _ ->
      Error (Some (Status.UnsupportedExtension, "unsupported extension"))

let heartbeat w span =
  let terminated = Ivar.create () in
  let stop = Deferred.any [ Pipe.closed w; Ivar.read terminated ] in
  let write_ping () =
    Log_async.debug (fun m -> m "-> PING") >>= fun () ->
    let ping = Frame.String.pingf "%a" Time_ns.pp (Time_ns.now ()) in
    Fastws_async_raw.write_frame w ping
  in
  Clock_ns.after span >>> fun () ->
  Clock_ns.run_at_intervals' ~continue_on_error:false ~stop span write_ping

let write_close st w fr =
  ( match Status.of_payload fr.Frame.payload with
  | Some status when Status.is_unknown status ->
      Bigstringaf.set_int16_be fr.payload 0 Status.(to_int ProtocolError)
  | _ -> () );
  match st.conn_state with
  | `Closed -> Deferred.unit
  | `Closing ->
      st.conn_state <- `Closed;
      write_frame_if_open w fr
  | `Open ->
      st.conn_state <- `Closing;
      write_frame w fr

let decr_conn_state st =
  st.conn_state <-
    ( match st.conn_state with
    | `Open -> `Closing
    | `Closing -> `Closed
    | `Closed -> `Closed )

let check_hdr_before_reassemble = function
  | Payload _ ->
      Log.debug (fun m -> m "<payload>");
      true
  | Header h ->
      Log.debug (fun m -> m "%a" Header.pp h);
      h.rsv = 0 && Opcode.is_std h.opcode

exception Closing of Frame.t

let closing fr = raise (Closing fr)

let mk_r3 of_frame st r2 w2 =
  Pipe.create_reader ~close_on_exception:false (fun to_r3 ->
      let close_all () =
        Pipe.close_read r2;
        Pipe.close w2;
        Pipe.close to_r3
      in
      Pipe.transfer' r2 to_r3 ~f:(fun q ->
          let ret = Queue.create () in
          let reassemble_and_process t =
            match check_hdr_before_reassemble t with
            | false ->
                closing
                @@ Frame.String.closef ~status:Status.ProtocolError
                     "invalid header"
            | _ -> (
                match reassemble st t with
                | Error msg ->
                    closing
                    @@ Frame.String.close
                         ~status:
                           ( Status.ProtocolError,
                             Some ("\000\000" ^ Error.to_string_hum msg) )
                         ()
                | Ok `Continue ->
                    Log_async.debug (fun m -> m "%a" pp st) >>= fun () ->
                    Deferred.unit
                | Ok (`Frame fr) -> (
                    Log_async.debug (fun m -> m "%a" pp st) >>= fun () ->
                    Log.debug (fun m -> m "<- %a" Frame.pp fr);
                    match r3_of_r2 st fr with
                    | Error None ->
                        (* got a close frame *)
                        decr_conn_state st;
                        closing fr
                    | Error (Some (status, msg)) ->
                        closing @@ Frame.String.closef ~status "%s" msg
                    | Ok (for_w2, for_r3) ->
                        Option.fold for_w2 ~init:Deferred.unit ~f:(fun _ ->
                            write_frame w2)
                        >>| fun () ->
                        Option.iter
                          ~f:(fun fr -> Queue.enqueue ret (of_frame fr))
                          for_r3 ) )
          in
          try_with ~extract_exn:true (fun () ->
              Deferred.Queue.iter q ~f:reassemble_and_process)
          >>= function
          | Ok () -> return ret
          | Error (Closing fr) ->
              write_close st w2 fr >>| fun () ->
              close_all ();
              Queue.create ()
          | Error exn -> raise exn))

let mk_w3 to_frame w2 =
  Pipe.create_writer (fun from_w3 ->
      Pipe.transfer' from_w3 w2 ~f:(fun pls ->
          let res = Queue.create () in
          Queue.iter pls ~f:(fun pl ->
              let { Frame.header; payload } = to_frame pl in
              Queue.enqueue res (Header header);
              match Bigstring.length payload with
              | 0 -> ()
              | _ -> Queue.enqueue res (Payload payload));
          return res))

type ('r, 'w) t = { r : 'r Pipe.Reader.t; w : 'w Pipe.Writer.t }

let create r w = { r; w }

let connect ?on_pong ?crypto ?extra_headers ?hb ~of_frame ~to_frame url =
  connect ?crypto ?extra_headers url >>= fun (r2, w2) ->
  let st = create_st ?on_pong () in
  Monitor.detach_and_iter_errors st.monitor ~f:(fun exn ->
      Log.err (fun m -> m "%a" Exn.pp exn);
      Pipe.close_read r2;
      Pipe.close w2);
  Option.iter hb ~f:(fun span ->
      Scheduler.within ~monitor:st.monitor (fun () -> heartbeat w2 span));
  let r3 = mk_r3 of_frame st r2 w2 in
  let w3 = mk_w3 to_frame w2 in
  (Pipe.closed r3 >>> fun () -> Pipe.close_read r2);
  ( Deferred.all_unit [ Pipe.closed w3; Pipe.closed r3 ] >>> fun () ->
    Pipe.close w2 );
  return (create r3 w3)

let with_connection ?on_pong ?crypto ?extra_headers ?hb ~of_frame ~to_frame uri
    f =
  connect ?on_pong ?extra_headers ?hb ?crypto ~of_frame ~to_frame uri
  >>= fun { r = r3; w = w3 } ->
  Monitor.protect
    (fun () -> f r3 w3)
    ~finally:(fun () ->
      Log_async.debug (fun m -> m "Fastws_async.with_connection: finally")
      >>= fun () ->
      Pipe.close_read r3;
      Pipe.close w3;
      Deferred.all_unit
        [
          (* Deferred.ignore_m (Pipe.upstream_flushed r3); *)
          (* Deferred.ignore_m (Pipe.downstream_flushed w3); *)
          Deferred.unit;
        ])

let of_frame_s { Frame.payload; _ } = Bigstring.to_string payload

let to_frame_s msg = Frame.String.textf "%s" msg

module type RW = sig
  type r

  type w
end

module MakePersistent (A : RW) = struct
  type nonrec t = (A.r, A.w) t

  module Address = Uri_sexp

  let is_closed { r; w; _ } = Pipe.(is_closed r && is_closed w)

  let close { r; w; _ } =
    Pipe.close w;
    Pipe.close_read r;
    Deferred.unit

  let close_finished { r; w; _ } =
    Deferred.all_unit [ Pipe.closed r; Pipe.closed w ]
end

(*---------------------------------------------------------------------------
   Copyright (c) 2020 DeepMarker

   Permission to use, copy, modify, and/or distribute this software for any
   purpose with or without fee is hereby granted, provided that the above
   copyright notice and this permission notice appear in all copies.

   THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
   WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
   MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
   ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
   WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
   ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
   OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
  ---------------------------------------------------------------------------*)
