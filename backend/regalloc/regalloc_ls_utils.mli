[@@@ocaml.warning "+a-4-30-40-41-42"]

open Regalloc_utils
module DLL = Flambda_backend_utils.Doubly_linked_list

val ls_debug : bool

val ls_verbose : bool Lazy.t

val ls_invariants : bool Lazy.t

val log :
  indent:int -> ?no_eol:unit -> ('a, Format.formatter, unit) format -> 'a

val log_body_and_terminator :
  indent:int ->
  Cfg.basic_instruction_list ->
  Cfg.terminator Cfg.instruction ->
  liveness ->
  unit

val log_cfg_with_infos : indent:int -> Cfg_with_infos.t -> unit

val iter_cfg_dfs : Cfg.t -> f:(Cfg.basic_block -> unit) -> unit

(* The [trap_handler] parameter to the [instruction] and [terminator] functions
   is set to [true] iff the instruction is the first one of a block which is a
   trap handler. *)
val iter_instructions_dfs :
  Cfg_with_layout.t ->
  instruction:(trap_handler:bool -> Cfg.basic Cfg.instruction -> unit) ->
  terminator:(trap_handler:bool -> Cfg.terminator Cfg.instruction -> unit) ->
  unit

module Range : sig
  (* Similar to [Interval.range] (in "backend/interval.mli"). *)
  type t =
    { mutable begin_ : int;
      mutable end_ : int
    }

  val copy : t -> t

  val print : Format.formatter -> t -> unit

  val overlap : t DLL.t -> t DLL.t -> bool

  val is_live : t DLL.t -> pos:int -> bool

  val remove_expired : t DLL.t -> pos:int -> unit
end

module Interval : sig
  (* Similar to [Interval.t] (in "backend/interval.mli"). *)
  type t =
    { reg : Reg.t;
      mutable begin_ : int;
      mutable end_ : int;
      ranges : Range.t DLL.t
    }

  val copy : t -> t

  val print : Format.formatter -> t -> unit

  val overlap : t -> t -> bool

  val is_live : t -> pos:int -> bool

  val remove_expired : t -> pos:int -> unit

  module List : sig
    val release_expired_fixed : t list -> pos:int -> t list

    val insert_sorted : t list -> t -> t list
  end

  module DLL : sig
    val release_expired_fixed : t DLL.t -> pos:int -> unit

    val insert_sorted : t DLL.t -> t -> unit
  end
end

module ClassIntervals : sig
  (* Similar to [Linscan.class_intervals] (in "backend/linscan.ml"). *)
  type t =
    { mutable fixed_list : Interval.t list;
      mutable active_list : Interval.t list;
      mutable inactive_list : Interval.t list;
      fixed_dll : Interval.t DLL.t;
      active_dll : Interval.t DLL.t;
      inactive_dll : Interval.t DLL.t
    }

  val make : unit -> t

  val copy : t -> t

  val print : Format.formatter -> t -> unit

  val clear : t -> unit

  val release_expired_intervals : t -> pos:int -> unit

  val check_consistency : t -> unit
end

val log_interval : indent:int -> kind:string -> Interval.t -> unit

val log_interval_list : indent:int -> kind:string -> Interval.t list -> unit

val log_interval_dll : indent:int -> kind:string -> Interval.t DLL.t -> unit
