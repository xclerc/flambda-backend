(* TEST
 flags = " -w -a ";
 setup-ocamlc.byte-build-env;
 ocamlc.byte;
 check-ocamlc.byte-output;
*)

type 'a t = 'a option
let is_some = function
  | None -> false
  | Some _ -> true

let should_accept ?x () = is_some x
