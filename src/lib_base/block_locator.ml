(**************************************************************************)
(*                                                                        *)
(*    Copyright (c) 2014 - 2018.                                          *)
(*    Dynamic Ledger Solutions, Inc. <contact@tezos.com>                  *)
(*                                                                        *)
(*    All rights reserved. No warranty, explicit or implicit, provided.   *)
(*                                                                        *)
(**************************************************************************)

open Lwt.Infix

type t = raw
and raw = Block_header.t * Block_hash.t list

let raw x = x

let pp ppf (hd, h_lst) =
  let repeats = 10 in
  let coef = 2 in
  (* list of hashes *)
  let rec pp_hash_list ppf (h_lst , acc , d , r) =
    match h_lst with
    | [] ->
        Format.fprintf ppf ""
    | hd :: tl ->
        let new_d = if r > 1 then d else d * coef in
        let new_r = if r > 1 then r - 1 else repeats in
        Format.fprintf ppf "%a (%i)\n%a"
          Block_hash.pp hd acc pp_hash_list (tl , acc - d , new_d , new_r) in
  Format.fprintf ppf "%a (head)\n%a"
    Block_hash.pp (Block_header.hash hd)
    pp_hash_list (h_lst , -1, 1, repeats - 1)

let pp_short ppf (hd, h_lst) =
  Format.fprintf ppf "head: %a, %d predecessors"
    Block_hash.pp (Block_header.hash hd)
    (List.length h_lst)

let encoding =
  let open Data_encoding in
  (* TODO add a [description] *)
  (obj2
     (req "current_head" (dynamic_size Block_header.encoding))
     (req "history" (dynamic_size (list Block_hash.encoding))))

type seed = {
  sender_id: P2p_peer.Id.t ;
  receiver_id: P2p_peer.Id.t ;
}

(* Random generator for locator steps.

   We draw steps by sequence of 10. The first sequence's steps are of
   length 1 (consecutive). The second sequence's steps are of a random
   length between 1 and 2. The third sequence's steps are of a random
   length between 2 and 4, and so on...

   The sequence is deterministic for a given triple of sender,
   receiver and block hash. *)
module Step : sig

  type state
  val init: seed -> Block_hash.t -> state
  val next: state -> int * state

end = struct

  type state = int * int * MBytes.t

  let init seed head =
    let open Hacl.Hash in
    let st = SHA256.init () in
    List.iter (SHA256.update st) [
      P2p_peer.Id.to_bytes seed.sender_id ;
      P2p_peer.Id.to_bytes seed.receiver_id ;
      Block_hash.to_bytes head ] ;
    (1, 9, SHA256.finish st)

  let draw seed n =
    Int32.to_int (MBytes.get_int32 seed 0) mod n,
    Hacl.Hash.SHA256.digest seed

  let next (step, counter, seed) =
    let random_gap, seed =
      if step <= 1 then
        0, seed
      else
        draw seed (1 + step/2) in
    let new_state =
      if counter = 0 then
        (step * 2, 9, seed)
      else
        (step, counter - 1, seed) in
    step - random_gap, new_state

end

let estimated_length seed (head, hist) =
  let rec loop acc state = function
    | [] -> acc
    | _ :: hist ->
        let step, state = Step.next state in
        loop (acc + step) state hist in
  let state = Step.init seed (Block_header.hash head) in
  let step, state = Step.next state in
  loop step state hist

let fold ~f ~init (head, hist) seed =
  let rec loop state acc = function
    | [] | [_] -> acc
    | block :: (pred :: rem as hist) ->
        let step, state = Step.next state in
        let acc = f acc ~block ~pred ~step ~strict_step:(rem <> []) in
        loop state acc hist in
  let head = Block_header.hash head in
  let state = Step.init seed head in
  loop state init (head :: hist)

type step = {
  block: Block_hash.t ;
  predecessor: Block_hash.t ;
  step: int ;
  strict_step: bool ;
}

let to_steps seed locator =
  fold locator seed
    ~init:[]
    ~f: begin fun acc ~block ~pred ~step ~strict_step ->
      { block ; predecessor = pred ; step ; strict_step } :: acc
    end

let compute ~predecessor ~genesis block_hash header seed ~size =
  let rec loop acc size state block =
    if size = 0 then
      Lwt.return (List.rev acc)
    else
      let step, state = Step.next state in
      predecessor block step >>= function
      | None ->
          (* We reached genesis before size *)
          if Block_hash.equal block genesis then
            Lwt.return (List.rev acc)
          else
            Lwt.return (List.rev (genesis :: acc))
      | Some pred ->
          loop (pred :: acc) (size - 1) state pred in
  if size <= 0 then
    Lwt.return (header, [])
  else
    let state = Step.init seed block_hash in
    let step, state = Step.next state in
    predecessor block_hash step >>= function
    | None -> Lwt.return (header, [])
    | Some p ->
        loop [p] (size-1) state p >>= fun hist ->
        Lwt.return (header, hist)

type validity =
  | Unknown
  | Known_valid
  | Known_invalid

let unknown_prefix ~is_known (head, hist) =
  let rec loop hist acc =
    match hist with
    | [] -> Lwt.return_none
    | h :: t ->
        is_known h >>= function
        | Known_valid ->
            Lwt.return_some (h, (List.rev (h :: acc)))
        | Known_invalid ->
            Lwt.return_none
        | Unknown ->
            loop t (h :: acc)
  in
  is_known (Block_header.hash head) >>= function
  | Known_valid ->
      Lwt.return_some (Block_header.hash head, (head, []))
  | Known_invalid ->
      Lwt.return_none
  | Unknown ->
      loop hist [] >>= function
      | None ->
          Lwt.return_none
      | Some (tail, hist) ->
          Lwt.return_some (tail, (head, hist))
