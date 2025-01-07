[@@@ocaml.warning "+a-4-30-40-41-42"]

open! Regalloc_utils
module DLL = Flambda_backend_utils.Doubly_linked_list

let ls_debug = false

let bool_of_param param_name =
  bool_of_param ~guard:(ls_debug, "ls_debug") param_name

let ls_verbose : bool Lazy.t = bool_of_param "LS_VERBOSE"

let ls_invariants : bool Lazy.t = bool_of_param "LS_INVARIANTS"

let log_function =
  lazy (make_log_function ~verbose:(Lazy.force ls_verbose) ~label:"ls")

let log :
    type a.
    indent:int -> ?no_eol:unit -> (a, Format.formatter, unit) format -> a =
 fun ~indent ?no_eol fmt -> (Lazy.force log_function).log ~indent ?no_eol fmt

let instr_prefix (instr : Cfg.basic Cfg.instruction) =
  Printf.sprintf "#%04d" instr.ls_order

let term_prefix (term : Cfg.terminator Cfg.instruction) =
  Printf.sprintf "#%04d" term.ls_order

let log_body_and_terminator :
    indent:int ->
    Cfg.basic_instruction_list ->
    Cfg.terminator Cfg.instruction ->
    liveness ->
    unit =
 fun ~indent body terminator liveness ->
  make_log_body_and_terminator (Lazy.force log_function) ~instr_prefix
    ~term_prefix ~indent body terminator liveness

let log_cfg_with_infos : indent:int -> Cfg_with_infos.t -> unit =
 fun ~indent cfg_with_infos ->
  make_log_cfg_with_infos (Lazy.force log_function) ~instr_prefix ~term_prefix
    ~indent cfg_with_infos

let iter_cfg_dfs : Cfg.t -> f:(Cfg.basic_block -> unit) -> unit =
 fun cfg ~f ->
  let marked = ref Label.Set.empty in
  let rec iter (label : Label.t) : unit =
    if not (Label.Set.mem label !marked)
    then (
      marked := Label.Set.add label !marked;
      let block = Cfg.get_block_exn cfg label in
      f block;
      Label.Set.iter
        (fun succ_label -> iter succ_label)
        (Cfg.successor_labels ~normal:true ~exn:true block))
  in
  iter cfg.entry_label;
  (* note: some block may not have been seen since we currently cannot remove
     all non-reachable blocks. *)
  if Label.Set.cardinal !marked <> Label.Tbl.length cfg.blocks
  then
    Cfg.iter_blocks cfg ~f:(fun label block ->
        if not (Label.Set.mem label !marked) then f block)

let iter_instructions_dfs :
    Cfg_with_layout.t ->
    instruction:(trap_handler:bool -> Cfg.basic Cfg.instruction -> unit) ->
    terminator:(trap_handler:bool -> Cfg.terminator Cfg.instruction -> unit) ->
    unit =
 fun cfg_with_layout ~instruction ~terminator ->
  let cfg = Cfg_with_layout.cfg cfg_with_layout in
  iter_cfg_dfs cfg ~f:(fun block ->
      let trap_handler_id =
        if block.is_trap_handler
        then Regalloc_utils.first_instruction_id block
        else min_int
      in
      DLL.iter block.body ~f:(fun instr ->
          instruction
            ~trap_handler:(Int.equal instr.Cfg.id trap_handler_id)
            instr);
      terminator
        ~trap_handler:(Int.equal block.terminator.Cfg.id trap_handler_id)
        block.terminator)

module Range = struct
  type t =
    { mutable begin_ : int;
      mutable end_ : int
    }

  let equal left right =
    Int.equal left.begin_ right.begin_ && Int.equal left.end_ right.end_

  let copy r = { begin_ = r.begin_; end_ = r.end_ }

  let print ppf r = Format.fprintf ppf "[%d,%d]" r.begin_ r.end_

  let rec overlap_cell : t DLL.cell option -> t DLL.cell option -> bool =
   fun left right ->
    match left, right with
    | Some left_cell, Some right_cell ->
      let left_value = DLL.value left_cell in
      let right_value = DLL.value right_cell in
      if left_value.end_ >= right_value.begin_
         && right_value.end_ >= left_value.begin_
      then true
      else if left_value.end_ < right_value.end_
      then overlap_cell (DLL.next left_cell) right
      else if left_value.end_ > right_value.end_
      then overlap_cell left (DLL.next right_cell)
      else overlap_cell (DLL.next left_cell) (DLL.next right_cell)
    | None, _ | _, None -> false

  let overlap : t DLL.t -> t DLL.t -> bool =
   fun left right -> overlap_cell (DLL.hd_cell left) (DLL.hd_cell right)

  let rec is_live_cell : t DLL.cell option -> pos:int -> bool =
   fun cell ~pos ->
    match cell with
    | None -> false
    | Some cell ->
      let value = DLL.value cell in
      if pos < value.begin_
      then false
      else if pos <= value.end_
      then true
      else is_live_cell (DLL.next cell) ~pos

  let is_live : t DLL.t -> pos:int -> bool =
   fun l ~pos -> is_live_cell (DLL.hd_cell l) ~pos

  let rec remove_expired_cell : t DLL.cell option -> pos:int -> unit =
   fun cell ~pos ->
    match cell with
    | None -> ()
    | Some cell ->
      let value = DLL.value cell in
      if pos < value.end_
      then ()
      else
        let next = DLL.next cell in
        DLL.delete_curr cell;
        remove_expired_cell next ~pos

  let remove_expired : t DLL.t -> pos:int -> unit =
   fun l ~pos -> remove_expired_cell (DLL.hd_cell l) ~pos
end

module Interval = struct
  type t =
    { reg : Reg.t;
      mutable begin_ : int;
      mutable end_ : int;
      ranges : Range.t DLL.t
    }

  let equal left right =
    Reg.same left.reg right.reg
    && Int.equal left.begin_ right.begin_
    && Int.equal left.end_ right.end_
    && DLL.equal Range.equal left.ranges right.ranges

  let copy t =
    { reg = t.reg;
      begin_ = t.begin_;
      end_ = t.end_;
      ranges = DLL.map t.ranges ~f:Range.copy
    }

  let print ppf t =
    Format.fprintf ppf "%a[%d,%d]:" Printreg.reg t.reg t.begin_ t.end_;
    DLL.iter t.ranges ~f:(fun r -> Format.fprintf ppf " %a" Range.print r)

  let overlap : t -> t -> bool =
   fun left right -> Range.overlap left.ranges right.ranges

  let is_live : t -> pos:int -> bool = fun t ~pos -> Range.is_live t.ranges ~pos

  let remove_expired : t -> pos:int -> unit =
   fun t ~pos -> Range.remove_expired t.ranges ~pos

  module List = struct
    let print ppf l =
      List.iter l ~f:(fun i -> Format.fprintf ppf "- %a\n" print i)

    let rec release_expired_fixed l ~pos =
      match l with
      | [] -> []
      | hd :: tl ->
        if hd.end_ >= pos
        then (
          remove_expired hd ~pos;
          hd :: release_expired_fixed tl ~pos)
        else []

    let rec insert_sorted l interval =
      match l with
      | [] -> [interval]
      | hd :: tl ->
        if hd.end_ <= interval.end_
        then interval :: l
        else hd :: insert_sorted tl interval
  end

  module DLL = struct
    let print ppf l =
      DLL.iter l ~f:(fun i -> Format.fprintf ppf "- %a\n" print i)

    let release_expired_fixed l ~pos =
      let rec aux curr ~pos =
        match curr with
        | None -> ()
        | Some cell ->
          let value = DLL.value cell in
          if value.end_ >= pos
          then (
            remove_expired value ~pos;
            aux (DLL.next cell) ~pos)
          else DLL.cut cell
      in
      aux (DLL.hd_cell l) ~pos

    let insert_sorted (l : t DLL.t) (interval : t) : unit =
      let rec aux l interval curr =
        match curr with
        | None -> DLL.add_end l interval
        | Some cell ->
          let value = DLL.value cell in
          if value.end_ <= interval.end_
          then DLL.insert_before cell interval
          else aux l interval (DLL.next cell)
      in
      aux l interval (DLL.hd_cell l)
  end
end

module ClassIntervals = struct
  type t =
    { mutable fixed_list : Interval.t list;
      mutable active_list : Interval.t list;
      mutable inactive_list : Interval.t list;
      fixed_dll : Interval.t DLL.t;
      active_dll : Interval.t DLL.t;
      inactive_dll : Interval.t DLL.t
    }

  let equal_list_dll eq list dll =
    let rec aux eq list cell =
      match list, cell with
      | [], None -> true
      | _ :: _, None | [], Some _ -> false
      | hd :: tl, Some cell ->
        let value = DLL.value cell in
        eq hd value && aux eq tl (DLL.next cell)
    in
    aux eq list (DLL.hd_cell dll)

  let make () =
    { fixed_list = [];
      active_list = [];
      inactive_list = [];
      fixed_dll = DLL.make_empty ();
      active_dll = DLL.make_empty ();
      inactive_dll = DLL.make_empty ()
    }

  let copy t =
    { fixed_list = List.map t.fixed_list ~f:Interval.copy;
      active_list = List.map t.active_list ~f:Interval.copy;
      inactive_list = List.map t.inactive_list ~f:Interval.copy;
      fixed_dll = DLL.map t.fixed_dll ~f:Interval.copy;
      active_dll = DLL.map t.active_dll ~f:Interval.copy;
      inactive_dll = DLL.map t.inactive_dll ~f:Interval.copy
    }

  let print ppf t =
    Format.fprintf ppf "fixed_list: %a\n" Interval.List.print t.fixed_list;
    Format.fprintf ppf "active_list: %a\n" Interval.List.print t.active_list;
    Format.fprintf ppf "inactive_list: %a\n" Interval.List.print t.inactive_list;
    Format.fprintf ppf "fixed_dll: %a\n" Interval.DLL.print t.fixed_dll;
    Format.fprintf ppf "active_dll: %a\n" Interval.DLL.print t.active_dll;
    Format.fprintf ppf "inactive_dll: %a\n" Interval.DLL.print t.inactive_dll

  let check_consistency t =
    let consistent_fixed =
      equal_list_dll Interval.equal t.fixed_list t.fixed_dll
    in
    let consistent_active =
      equal_list_dll Interval.equal t.active_list t.active_dll
    in
    let consistent_inactive =
      equal_list_dll Interval.equal t.inactive_list t.inactive_dll
    in
    if not (consistent_fixed && consistent_active && consistent_inactive)
    then (
      print Format.err_formatter t;
      Misc.fatal_errorf
        "Regalloc_ls_utils.ClassIntervals.check_consistency \
         (consistent_fixed=%B consistent_active=%B consistent_inactive=%B)"
        consistent_fixed consistent_active consistent_inactive)

  let clear t =
    t.fixed_list <- [];
    t.active_list <- [];
    t.inactive_list <- [];
    DLL.clear t.fixed_dll;
    DLL.clear t.active_dll;
    DLL.clear t.inactive_dll

  module List = struct
    let rec release_expired_active t ~pos l =
      match l with
      | [] -> []
      | hd :: tl ->
        if hd.Interval.end_ >= pos
        then (
          Interval.remove_expired hd ~pos;
          if Interval.is_live hd ~pos
          then hd :: release_expired_active t ~pos tl
          else (
            t.inactive_list <- Interval.List.insert_sorted t.inactive_list hd;
            release_expired_active t ~pos tl))
        else []

    let rec release_expired_inactive t ~pos l =
      match l with
      | [] -> []
      | hd :: tl ->
        if hd.Interval.end_ >= pos
        then (
          Interval.remove_expired hd ~pos;
          if not (Interval.is_live hd ~pos)
          then hd :: release_expired_inactive t ~pos tl
          else (
            t.active_list <- Interval.List.insert_sorted t.active_list hd;
            release_expired_inactive t ~pos tl))
        else []
  end

  module DLL = struct
    let release_expired_active (t : t) ~(pos : int) (l : Interval.t DLL.t) :
        unit =
      let rec aux t ~pos curr : unit =
        match curr with
        | None -> ()
        | Some cell ->
          let value = DLL.value cell in
          if value.Interval.end_ >= pos
          then (
            Interval.remove_expired value ~pos;
            if Interval.is_live value ~pos
            then aux t ~pos (DLL.next cell)
            else (
              Interval.DLL.insert_sorted t.inactive_dll value;
              let next = DLL.next cell in
              DLL.delete_curr cell;
              aux t ~pos next))
          else DLL.cut cell
      in
      aux t ~pos (DLL.hd_cell l)

    let release_expired_inactive (t : t) ~(pos : int) (l : Interval.t DLL.t) :
        unit =
      let rec aux t ~pos curr =
        match curr with
        | None -> ()
        | Some cell ->
          let value = DLL.value cell in
          if value.Interval.end_ >= pos
          then (
            Interval.remove_expired value ~pos;
            if not (Interval.is_live value ~pos)
            then aux t ~pos (DLL.next cell)
            else (
              Interval.DLL.insert_sorted t.active_dll value;
              let next = DLL.next cell in
              DLL.delete_curr cell;
              aux t ~pos next))
          else DLL.cut cell
      in
      aux t ~pos (DLL.hd_cell l)
  end

  let release_expired_intervals t ~pos =
    t.fixed_list <- Interval.List.release_expired_fixed t.fixed_list ~pos;
    t.active_list <- List.release_expired_active t ~pos t.active_list;
    t.inactive_list <- List.release_expired_inactive t ~pos t.inactive_list;
    Interval.DLL.release_expired_fixed t.fixed_dll ~pos;
    DLL.release_expired_active t ~pos t.active_dll;
    DLL.release_expired_inactive t ~pos t.inactive_dll
end

let log_interval ~indent ~kind (interval : Interval.t) =
  let reg_class = Proc.register_class interval.reg in
  log ~indent "%s %a (class %d) [%d..%d]" kind Printreg.reg interval.reg
    reg_class interval.begin_ interval.end_;
  let ranges = Buffer.create 128 in
  let first = ref true in
  DLL.iter interval.ranges ~f:(fun { Range.begin_; end_ } ->
      if !first then first := false else Buffer.add_string ranges ", ";
      Buffer.add_string ranges (Printf.sprintf "[%d..%d]" begin_ end_));
  log ~indent:(succ indent) "%s" (Buffer.contents ranges)

let log_interval_list ~indent ~kind (intervals : Interval.t list) =
  List.iter intervals ~f:(fun (interval : Interval.t) ->
      log_interval ~indent ~kind interval)

let log_interval_dll ~indent ~kind (intervals : Interval.t DLL.t) =
  DLL.iter intervals ~f:(fun (interval : Interval.t) ->
      log_interval ~indent ~kind interval)

(* let f () : unit = let ( !$ ) = Format.eprintf in !$"a" *)
