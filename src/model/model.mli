
(* This file is free software, part of dolmen. See file "LICENSE" for more information *)

(** {2 Type definitions} *)
(** ************************************************************************ *)

type t
(** The type of environments for evaluations. *)

val empty : t
(* The empty env. *)

(** {2 Variables and Constants values} *)
(** ************************************************************************ *)

module type S = sig

  type key

  val find_opt : key -> t -> Value.t option

  val add : key -> Value.t -> t -> t

end

module Var : S with type key := Dolmen.Std.Expr.Term.Var.t
module Cst : S with type key := Dolmen.Std.Expr.Term.Const.t

