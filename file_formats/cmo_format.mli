(**************************************************************************)
(*                                                                        *)
(*                                 OCaml                                  *)
(*                                                                        *)
(*             Xavier Leroy, projet Cristal, INRIA Rocquencourt           *)
(*                                                                        *)
(*   Copyright 2006 Institut National de Recherche en Informatique et     *)
(*     en Automatique.                                                    *)
(*                                                                        *)
(*   All rights reserved.  This file is distributed under the terms of    *)
(*   the GNU Lesser General Public License version 2.1, with the          *)
(*   special exception on linking described in the file LICENSE.          *)
(*                                                                        *)
(**************************************************************************)

(* Symbol table information for .cmo and .cma files *)

<<<<<<< HEAD
||||||| 121bedcfd2
open Misc

=======
type modname = string
type crcs = (modname * Digest.t option) list

(* Names of compilation units as represented in CMO files *)
type compunit = Compunit of string [@@unboxed]

(* Predefined symbols as represented in CMO files *)

type predef =
  | Predef_exn of string [@@unboxed]

>>>>>>> 5.2.0
(* Relocation information *)

type reloc_info =
  | Reloc_literal of Obj.t (* structured constant *)
  | Reloc_getcompunit of compunit (* reference to a compunit *)
  | Reloc_getpredef of predef (* reference to a predef *)
  | Reloc_setcompunit of compunit (* definition of a compunit *)
  | Reloc_primitive of string (* C primitive number *)

(* Descriptor for compilation units *)

<<<<<<< HEAD
type compilation_unit_descr =
  { cu_name: Compilation_unit.t;        (* Name of compilation unit *)
||||||| 121bedcfd2
type compilation_unit =
  { cu_name: modname;                   (* Name of compilation unit *)
=======
type compilation_unit =
  { cu_name: compunit;                   (* Name of compilation unit *)
>>>>>>> 5.2.0
    mutable cu_pos: int;                (* Absolute position in file *)
    cu_codesize: int;                   (* Size of code block *)
    cu_reloc: (reloc_info * int) list;  (* Relocation information *)
<<<<<<< HEAD
    cu_imports: Import_info.t array;    (* Names and CRC of intfs imported *)
    cu_required_globals: Compilation_unit.t list;
                                        (* Compilation units whose
                                           initialization side effects
                                           must occur before this one. *)
||||||| 121bedcfd2
    cu_imports: crcs;                   (* Names and CRC of intfs imported *)
    cu_required_globals: Ident.t list;  (* Compilation units whose
                                           initialization side effects
                                           must occur before this one. *)
=======
    cu_imports: crcs;                     (* Names and CRC of intfs imported *)
    cu_required_compunits: compunit list; (* Compilation units whose
                                             initialization side effects
                                             must occur before this one. *)
>>>>>>> 5.2.0
    cu_primitives: string list;         (* Primitives declared inside *)
    mutable cu_force_link: bool;        (* Must be linked even if unref'ed *)
    mutable cu_debug: int;              (* Position of debugging info, or 0 *)
    cu_debugsize: int }                 (* Length of debugging info *)

(* Format of a .cmo file:
     magic number (Config.cmo_magic_number)
     absolute offset of compilation unit descriptor
     block of relocatable bytecode
     debugging information if any
     compilation unit descriptor *)

(* Descriptor for libraries *)

type library =
  { lib_units: compilation_unit_descr list; (* List of compilation units *)
    lib_custom: bool;                   (* Requires custom mode linking? *)
    (* In the following fields the lists are reversed with respect to
       how they end up being used on the command line. *)
    lib_ccobjs: string list;            (* C object files needed for -custom *)
    lib_ccopts: string list;            (* Extra opts to C compiler *)
    lib_dllibs: string list }           (* DLLs needed *)

(* Format of a .cma file:
     magic number (Config.cma_magic_number)
     absolute offset of library descriptor
     object code for first library member
     ...
     object code for last library member
     library descriptor *)
