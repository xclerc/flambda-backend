type 'a node =
  | Empty
  | Node of
      { mutable value : 'a;
        mutable prev : 'a node;
        mutable next : 'a node
      }

let[@inline] unattached_node value = Node { value; prev = Empty; next = Empty }

type 'a t =
  { mutable first : 'a node;
    mutable last : 'a node
  }

type 'a cell =
  { node : 'a node; (* invariant: this node is not empty/dummy *)
    t : 'a t
  }

let insert_and_return_before cell value =
  match unattached_node value with
  | Empty ->
    (* internal invariant: unattached node returns a non-empty node *)
    assert false
  | Node new_node as value_node -> (
    match cell.node with
    | Empty ->
      (* internal invariant: cell's nodes are not empty *)
      assert false
    | Node cell_node ->
      new_node.next <- cell.node;
      new_node.prev <- cell_node.prev;
      cell_node.prev <- value_node;
      (match new_node.prev with
      | Empty -> cell.t.first <- value_node
      | Node node -> node.next <- value_node);
      { node = value_node; t = cell.t })

let insert_before cell value =
  let _new_cell : _ cell = insert_and_return_before cell value in
  ()

let insert_and_return_after cell value =
  match unattached_node value with
  | Empty -> assert false
  | Node new_node as value_node -> (
    match cell.node with
    | Empty ->
      (* internal invariant: cell's nodes are not empty *)
      assert false
    | Node cell_node ->
      (new_node.next <- cell_node.next;
       new_node.prev <- cell.node;
       cell_node.next <- value_node;
       match new_node.next with
       | Empty -> cell.t.last <- value_node
       | Node node -> node.prev <- value_node);
      { node = value_node; t = cell.t })

let insert_after cell value =
  let _new_cell : _ cell = insert_and_return_after cell value in
  ()

let value cell =
  match cell.node with
  | Empty ->
    (* internal invariant: cell's nodes are not empty *)
    assert false
  | Node node -> node.value

let set_value cell v =
  match cell.node with
  | Empty ->
    (* internal invariant: cell's nodes are not empty *)
    assert false
  | Node node -> node.value <- v

let prev cell =
  match cell.node with
  | Empty ->
    (* internal invariant: cell's nodes are not empty *)
    assert false
  | Node cell_node -> (
    let prev = cell_node.prev in
    match prev with Empty -> None | Node _ -> Some { node = prev; t = cell.t })

let next cell =
  match cell.node with
  | Empty ->
    (* internal invariant: cell's nodes are not empty *)
    assert false
  | Node cell_node -> (
    let next = cell_node.next in
    match next with Empty -> None | Node _ -> Some { node = next; t = cell.t })

let make_empty () = { first = Empty; last = Empty }

let make_single value =
  let node = unattached_node value in
  { first = node; last = node }

let clear t =
  t.first <- Empty;
  t.last <- Empty

let hd t = match t.first with Empty -> None | Node { value; _ } -> Some value

let hd_cell t = match t.first with Empty -> None | node -> Some { node; t }

let last t = match t.last with Empty -> None | Node { value; _ } -> Some value

let last_cell t = match t.last with Empty -> None | node -> Some { node; t }

let add_begin t value =
  match unattached_node value with
  | Empty ->
    (* internal invariant: unattached node returns a non-empty node *)
    assert false
  | Node node as value_node -> (
    match t.first with
    | Empty ->
      assert (t.last = Empty);
      t.first <- value_node;
      t.last <- value_node
    | Node first_node ->
      node.next <- t.first;
      first_node.prev <- value_node;
      t.first <- value_node)

let add_end t value =
  match unattached_node value with
  | Empty ->
    (* internal invariant: unattached node returns a non-empty node *)
    assert false
  | Node node as value_node -> (
    match t.last with
    | Empty ->
      assert (t.first = Empty);
      t.first <- value_node;
      t.last <- value_node
    | Node last_node ->
      node.prev <- t.last;
      last_node.next <- value_node;
      t.last <- value_node)

let add_list t l = List.iter (fun x -> add_end t x) l

let of_list l =
  let res = make_empty () in
  add_list res l;
  res

let is_empty (t : _ t) =
  match t.first with
  | Empty -> true
  | Node _ -> false
let length t =
  let rec aux acc curr =
    match curr with
    | Empty -> acc
    | Node { value = _; prev = _; next; } -> aux (succ acc) next
  in
  aux 0 t.first

let remove t curr =
  match curr with
  | Empty ->
    (* internal invariant: the node given to [remove] is never empty *)
    assert false
  | Node curr ->
    (match curr.prev with
    | Empty -> t.first <- curr.next
    | Node node -> node.next <- curr.next);
    (match curr.next with
    | Empty -> t.last <- curr.prev
    | Node node -> node.prev <- curr.prev)

let delete_curr cell = remove cell.t cell.node

let delete_before cell =
  match cell.node with
  | Empty ->
    (* internal invariant: cell's nodes are not empty *)
    assert false
  | Node cell_node -> (
    match cell_node.prev with
    | Empty ->
      (* convention: cannot delete_before the first element in the list *)
      assert false
    | Node _prev_cell_node -> delete_curr { node = cell_node.prev; t = cell.t })

let delete_after cell =
  match cell.node with
  | Empty ->
    (* internal invariant: cell's nodes are not empty *)
    assert false
  | Node cell_node -> (
    match cell_node.next with
    | Empty ->
      (* convention: cannot delete_after the last element in the list *)
      assert false
    | Node _next_cell_node -> delete_curr { node = cell_node.next; t = cell.t })

let remove_first : 'a t -> f:('a -> bool) -> unit =
 fun t ~f ->
  let rec aux t f curr =
    match curr with
    | Empty -> () (* no node removed *)
    | Node node -> if f node.value then remove t curr else aux t f node.next
  in
  aux t f t.first

let filter_left t ~f =
  let rec aux t f curr =
    match curr with
    | Empty -> ()
    | Node node ->
      if not (f node.value) then remove t curr;
      aux t f node.next
  in
  aux t f t.first

let filter_right t ~f =
  let rec aux t f curr =
    match curr with
    | Empty -> ()
    | Node node ->
      if not (f node.value) then remove t curr;
      aux t f node.prev
  in
  aux t f t.last

let iter t ~f =
  let rec aux f curr =
    match curr with
    | Empty -> ()
    | Node node ->
      f node.value;
      aux f node.next
  in
  aux f t.first

let iter_cell t ~f =
  let rec aux t f curr =
    match curr with
    | Empty -> ()
    | Node node ->
      let next = node.next in
      let cell = { node = curr; t } in
      f cell;
      aux t f next
  in
  aux t f t.first

let iter_right_cell t ~f =
  let rec aux t f curr =
    match curr with
    | Empty -> ()
    | Node node ->
      let prev = node.prev in
      let cell = { node = curr; t } in
      f cell;
      aux t f prev
  in
  aux t f t.last

let iteri t ~f =
  let rec aux f i curr =
    match curr with
    | Empty -> ()
    | Node node ->
      f i node.value;
      aux f (i + 1) node.next
  in
  aux f 0 t.first

let iter2 t t' ~f =
  let rec aux f curr curr' =
    match curr, curr' with
    | Empty, Empty -> ()
    | Node node, Node node' ->
      f node.value node'.value;
      aux f node.next node'.next
    | Node _, Empty | Empty, Node _ -> invalid_arg "DoublyLinkedList.iter2"
  in
  aux f t.first t'.first

let fold_left t ~f ~init =
  let rec aux f curr acc =
    match curr with
    | Empty -> acc
    | Node node -> aux f node.next (f acc node.value)
  in
  aux f t.first init

let fold_right t ~f ~init =
  let rec aux f curr acc =
    match curr with
    | Empty -> acc
    | Node node -> aux f node.prev (f node.value acc)
  in
  aux f t.last init

let find_cell_opt t ~f =
  let rec aux t f curr =
    match curr with
    | Empty -> None
    | Node node ->
      if f node.value then Some { node = curr; t } else aux t f node.next
  in
  aux t f t.first

let find_opt t ~f =
  match find_cell_opt t ~f with
  | None -> None
  | Some { node = Empty; _ } ->
    (* internal invariant: cell's nodes are not empty *)
    assert false
  | Some { node = Node { value; prev = _; next = _ }; t = _ } -> Some value

let exists t ~f =
  let rec aux t f curr =
    match curr with
    | Empty -> false
    | Node node -> if f node.value then true else aux t f node.next
  in
  aux t f t.first

let for_all t ~f =
  let rec aux t f curr =
    match curr with
    | Empty -> true
    | Node node -> if f node.value then aux t f node.next else false
  in
  aux t f t.first

let to_list t = fold_right t ~f:(fun hd tl -> hd :: tl) ~init:[]

let transfer ~to_ ~from () =
  match to_.last, from.first with
  | _, Empty ->
    (* nothing to do *)
    ()
  | Empty, _ ->
    to_.first <- from.first;
    to_.last <- from.last;
    from.first <- Empty;
    from.last <- Empty
  | Node to_last, Node from_first ->
    to_last.next <- from.first;
    from_first.prev <- to_.last;
    to_.last <- from.last;
    from.first <- Empty;
    from.last <- Empty

let map t ~f =
  let res = make_empty () in
  iter t ~f:(fun x -> add_end res (f x));
  res

let copy t = map t ~f:Fun.id

let cut cell =
  (* XXX optimize *)
  let rec aux curr =
    match curr with
    | None -> ()
    | Some cell ->
      let next_cell = next cell in
      delete_curr cell;
      aux next_cell
  in
  aux (Some cell)

  let equal eq left right =
    let rec aux eq left right =
      match left, right with
      | None, None -> true
      | (None, (Some _)) | ((Some _), None) -> false
      | Some left_cell, Some right_cell ->
        let left_value = value left_cell in
        let right_value = value right_cell in
        eq left_value right_value && aux eq (next left_cell) (next right_cell)
    in
    aux eq (hd_cell left) (hd_cell right)