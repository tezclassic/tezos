(**************************************************************************)
(*                                                                        *)
(*    Copyright (c) 2014 - 2018.                                          *)
(*    Dynamic Ledger Solutions, Inc. <contact@tezos.com>                  *)
(*                                                                        *)
(*    All rights reserved. No warranty, explicit or implicit, provided.   *)
(*                                                                        *)
(**************************************************************************)

(** Return type for service handler *)
type 'o t =
  [ `Ok of 'o (* 200 *)
  | `OkStream of 'o stream (* 200 *)
  | `Created of string option (* 201 *)
  | `No_content (* 204 *)
  | `Unauthorized of RPC_service.error option (* 401 *)
  | `Forbidden of RPC_service.error option (* 403 *)
  | `Not_found of RPC_service.error option (* 404 *)
  | `Conflict of RPC_service.error option (* 409 *)
  | `Error of RPC_service.error option (* 500 *)
  ]

and 'a stream = 'a Resto_directory.Answer.stream = {
  next: unit -> 'a option Lwt.t ;
  shutdown: unit -> unit ;
}

val return: 'o -> 'o t Lwt.t
val return_stream: 'o stream -> 'o t Lwt.t
val not_found: 'o t Lwt.t

val fail: Error_monad.error list -> 'a t Lwt.t
