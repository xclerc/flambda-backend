(**************************************************************************)
(*                                                                        *)
(*                                 OCaml                                  *)
(*                                                                        *)
(*                       Pierre Chambart, OCamlPro                        *)
(*           Mark Shinwell and Leo White, Jane Street Europe              *)
(*                                                                        *)
(*   Copyright 2013--2019 OCamlPro SAS                                    *)
(*   Copyright 2014--2019 Jane Street Group LLC                           *)
(*                                                                        *)
(*   All rights reserved.  This file is distributed under the terms of    *)
(*   the GNU Lesser General Public License version 2.1, with the          *)
(*   special exception on linking described in the file LICENSE.          *)
(*                                                                        *)
(**************************************************************************)

(** Classification of application expressions. *)

module Function_call : sig
  type t = private
    | Direct of Code_id.t
        (** The [code_id] uniquely determines the function symbol that
            must be called. *)
    | Indirect_unknown_arity
    | Indirect_known_arity
end

module Method_kind : sig
  type t = private
    | Self
    | Public
    | Cached

  val from_lambda : Lambda.meth_kind -> t

  val to_lambda : t -> Lambda.meth_kind
end

(* CR mshinwell: consider refactoring [Call_kind] so that there wouldn't be a
   separate callee field for cases like this. *)

(** Algebraic effect operations.  The corresponding [Apply_expr] will have the
    callee set to [None] and an empty argument list for these.  This is done
    to ensure there is no confusion between the different [Simple]s. *)
module Effect : sig
  type t = private
    | Perform of { eff : Simple.t }
    | Reperform of
        { eff : Simple.t;
          cont : Simple.t;
          last_fiber : Simple.t
        }
    | Run_stack of
        { stack : Simple.t;
          f : Simple.t;
          arg : Simple.t
        }
    | Resume of
        { stack : Simple.t;
          f : Simple.t;
          arg : Simple.t;
          last_fiber : Simple.t
        }

  include Contains_names.S with type t := t

  val perform : eff:Simple.t -> t

  val reperform : eff:Simple.t -> cont:Simple.t -> last_fiber:Simple.t -> t

  val run_stack : stack:Simple.t -> f:Simple.t -> arg:Simple.t -> t

  val resume :
    stack:Simple.t -> f:Simple.t -> arg:Simple.t -> last_fiber:Simple.t -> t
end

(* The allocation mode corresponds to the type of the function that is called:
   if the function has return mode [Heap], then the alloc_mode is [Heap] as
   well; if the function has return mode [Local], then the alloc_mode is [Local
   {region}] where the result must be allocated in the region [region]. Note
   that even if the result does not need to be allocated (as in [unit -> local_
   unit]), the function is still permitted to allocate in [region] in that
   case. *)

(** Whether an application expression corresponds to an OCaml function
    invocation, an OCaml method invocation, or an external call. *)
type t = private
  | Function of
      { function_call : Function_call.t;
        alloc_mode : Alloc_mode.For_applications.t
      }
  | Method of
      { kind : Method_kind.t;
        obj : Simple.t;
        alloc_mode : Alloc_mode.For_applications.t
      }
  | C_call of
      { needs_caml_c_call : bool;
        is_c_builtin : bool;
        effects : Effects.t;
        coeffects : Coeffects.t;
        alloc_mode : Alloc_mode.For_applications.t
      }
  | Effect of Effect.t

include Expr_std.S with type t := t

include Contains_ids.S with type t := t

val direct_function_call : Code_id.t -> Alloc_mode.For_applications.t -> t

val indirect_function_call_unknown_arity : Alloc_mode.For_applications.t -> t

val indirect_function_call_known_arity : Alloc_mode.For_applications.t -> t

val method_call :
  Method_kind.t -> obj:Simple.t -> Alloc_mode.For_applications.t -> t

val c_call :
  needs_caml_c_call:bool ->
  is_c_builtin:bool ->
  effects:Effects.t ->
  coeffects:Coeffects.t ->
  Alloc_mode.For_applications.t ->
  t

val effect : Effect.t -> t
