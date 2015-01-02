open S

module type TABLE = sig
  val clear : unit -> unit
  type value
  val get : value -> int
  val unget : int -> value
end

module type TABLE_VALUE = sig
  type t
  val hash : t -> int
  val equal : t -> t -> bool
end

module PersistentTable (Value : TABLE_VALUE) : TABLE
  with type value = Value.t = struct

  module T = Hashtbl.Make (Value)
  (* TODO(arjun): Since these are allocated contiguously, it would be
     better to use a growable array ArrayList<Int> *)
  module U = Hashtbl.Make(struct
    type t = int
    let hash n = n
    let equal x y = x = y
  end)

  type value = Value.t

  let tbl : int T.t = T.create 100
  let untbl : value U.t = U.create 100

  let idx = ref 0

  let clear () =
    T.clear tbl;
    U.clear untbl;
    idx := 0

  let gensym () =
    let r = !idx in
    idx := !idx + 1;
    r

  let get (v : value) =
    try
      T.find tbl v
    with Not_found ->
      begin
        let n = gensym () in
        T.add tbl v n;
        U.add untbl n v;
        n
      end

  let unget (idx : int) : value = U.find untbl idx

end

module Make(V:HashCmp)(L:Lattice)(R:Result) = struct
  type v = V.t * L.t
  type r = R.t

  type d
    = Leaf of r
    | Branch of V.t * L.t * int * int

  type t = int
  module T = PersistentTable(struct
      type t = d

      let hash t = match t with
        | Leaf r ->
          (R.hash r) lsl 1
        | Branch(v, l, t, f) ->
          (1021 * (V.hash v) + 1031 * (L.hash l) + 1033 * t + 1039 * f) lor 0x1

      let equal a b = match a, b with
        | Leaf r1, Leaf r2 -> R.compare r1 r2 = 0
        | Branch(vx, lx, tx, fx), Branch(vy, ly, ty, fy) ->
          V.compare vx vy = 0 && tx = ty && fx = fy
            && L.compare lx ly = 0
        | _, _ -> false
    end)

  (* A tree structure representing the decision diagram. The [Leaf] variant
   * represents a constant function. The [Branch(v, l, t, f)] represents an
   * if-then-else. When variable [v] takes on the value [l], then [t] should
   * hold. Otherwise, [f] should hold.
   *
   * [Branch] nodes appear in an order determined first by the total order on
   * the [V.t] value with with ties broken by the total order on [L.t]. The
   * least such pair should appear at the root of the diagram, with each child
   * nodes being strictly greater than their parent node. This invariant is
   * important both for efficiency and correctness.
   * *)

  let equal x y = x = y (* comparing ints *)

  let rec to_string t = "to_string broken" (* match T.get t with
    | Leaf r             -> R.to_string r
    | Branch(v, l, t, f) -> Printf.sprintf "B(%s = %s, %s, %s)"
      (V.to_string v) (L.to_string l) (to_string t)
      (to_string (T.get f))
 *)
  let clear_cache () = T.clear ()

  let mk_leaf r = T.get (Leaf r)

  let mk_branch v l t f =
    (* When the ids of the diagrams are equal, then the diagram will take on the
       same value regardless of variable assignment. The node that's being
       constructed can therefore be eliminated and replaced with one of the
       sub-diagrams, which are identical.

       If the ids are distinct, then the node has to be constructed and assigned
       a new id. *)
    if equal t f then begin
      t
    end else
      T.get (Branch(v, l, t, f))

  let rec fold g h t = match T.unget t with
    | Leaf r -> g r
    | Branch(v, l, t, f) ->
      h (v, l) (fold g h t) (fold g h f)

  let const r = mk_leaf r
  let atom (v, l) t f = mk_branch v l (const t) (const f)

  let restrict lst =
    let rec loop xs u =
      match xs, T.unget u with
      | []          , _
      | _           , Leaf _ -> u
      | (v,l) :: xs', Branch(v', l', t, f) ->
        match V.compare v v' with
        |  0 -> if L.subset_eq l l' then loop xs' t else loop xs f
        | -1 -> loop xs' u
        |  1 -> mk_branch v' l' (loop xs t) (loop xs f)
        |  _ -> assert false
    in
    loop (List.sort (fun (u, _) (v, _) -> V.compare u v) lst)

  let peek t = match T.unget t with
    | Leaf r   -> Some r
    | Branch _ -> None

  let rec map_r g = fold
    (fun r          -> const (g r))
    (fun (v, l) t f -> mk_branch v l t f)

  let rec prod x y =
    match T.unget x, T.unget y with
    | Leaf r, _      ->
      if R.(compare r zero) = 0 then x
      else if R.(compare r one) = 0 then y
      else map_r (R.prod r) y
    | _     , Leaf r ->
      if R.(compare zero r) = 0 then y
      else if R.(compare one r) = 0 then x
      else map_r (fun x -> R.prod x r) x
    | Branch(vx, lx, tx, fx), Branch(vy, ly, ty, fy) ->
      begin match V.compare vx vy with
      |  0 ->
        begin match L.meet ~tight:true lx ly with
        | Some(l) -> mk_branch vx l (prod tx ty) (prod fx fy)
        | None    ->
          begin match L.compare lx ly with
          |  0 -> assert false
          | -1 -> mk_branch vx lx (prod tx (restrict [(vx, lx)] y)) (prod fx y)
          |  1 -> mk_branch vy ly (prod (restrict [(vy, ly)] x) ty) (prod x fy)
          |  _ -> assert false
          end
        end
      | -1 -> mk_branch vx lx (prod tx y) (prod fx y)
      |  1 -> mk_branch vy ly (prod x ty) (prod x fy)
      |  _ -> assert false
      end

  let rec sum x y =
    match T.unget x, T.unget y with
    | Leaf r, _      ->
      if R.(compare r zero) = 0 then y
      else map_r (R.sum r) y
    | _     , Leaf r ->
      if R.(compare zero r) = 0 then x
      else map_r (fun x -> R.sum x r) x
    | Branch(vx, lx, tx, fx), Branch(vy, ly, ty, fy) ->
      begin match V.compare vx vy with
      |  0 ->
        begin match L.join ~tight:true lx ly with
        | Some(l) -> mk_branch vx l (sum tx ty) (sum fx fy)
        | None    ->
          begin match L.compare lx ly with
          |  0 -> assert false
          | -1 -> mk_branch vx lx (sum tx (restrict [(vx, lx)] y)) (sum fx y)
          |  1 -> mk_branch vy ly (sum (restrict [(vy, ly)] x) ty) (sum x fy)
          |  _ -> assert false
          end
        end
      | -1 -> mk_branch vx lx (sum tx y) (sum fx y)
      |  1 -> mk_branch vy ly (sum x ty) (sum x fy)
      |  _ -> assert false
      end

end
