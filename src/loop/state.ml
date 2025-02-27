
(* This file is free software, part of dolmen. See file "LICENSE" for more information *)

(* Type definition *)
(* ************************************************************************* *)

module M = Dolmen.Std.Hmap.Make(struct
    type t = int
    let compare (a: int) (b: int) = compare a b
  end)

type t = M.t

type 'a key = {
  id : int;
  name : string;
  inj : 'a Dolmen.Std.Hmap.injection;
}

type report_style =
  | Minimal
  | Regular
  | Contextual

type source = [
  | `Stdin
  | `File of string
  | `Raw of string * string
]

type mode = [
  | `Full
  | `Incremental
]

type 'lang file = {
  lang    : 'lang option;
  mode    : mode option;
  loc     : Dolmen.Std.Loc.file;
  dir     : string;
  source  : source;
}

exception Error of t
exception Key_not_found of t * string

(* Signatures *)
(* ************************************************************************* *)

module type S = sig

  type t
  (** The type of state *)

  type 'a key
  (** The type of keys into the state. *)

  exception Error of t
  (** Convenient exception. *)

  exception Key_not_found of t * string
  (** Exception raised by `get` when the key is not bound. *)

  val create_key : string -> _ key
  (** create a new key *)

  val get : 'a key -> t -> 'a
  (** get the value associated to a key. *)

  val set : 'a key -> 'a -> t -> t
  (** Set the value associated to a key. *)

  val warn :
    ?file:_ file ->
    ?loc:Dolmen.Std.Loc.full ->
    t -> 'a Report.Warning.t -> 'a -> t
  (** Emit a warning *)

  val error :
    ?file:_ file ->
    ?loc:Dolmen.Std.Loc.full ->
    t -> 'a Report.Error.t -> 'a -> t
  (** Emit an error. *)

  val debug : bool key
  val reports : Report.Conf.t key
  val report_style : report_style key
  val max_warn : int key
  val cur_warn : int key
  val time_limit : float key
  val size_limit : float key
  val logic_file : Logic.language file key
  val response_file : Response.language file key
  (* common keys *)

end

(* Key functions *)
(* ************************************************************************* *)

let empty : t = M.empty

let key_counter = ref 0
let create_key name =
  incr key_counter;
  { id = !key_counter; name;
    inj = Dolmen.Std.Hmap.create_inj ();}

let get k t =
  match M.get ~inj:k.inj k.id t with
  | Some v -> v
  | None -> raise (Key_not_found (t, k.name))

let set k v t =
  M.add ~inj:k.inj k.id v t

let update k f t =
  set k (f (get k t)) t


(* Some common keys *)
(* ************************************************************************* *)

let debug : bool key = create_key "debug"
let reports : Report.Conf.t key = create_key "reports"
let report_style : report_style key = create_key "report_style"
let max_warn : int key = create_key "max_warn"
let cur_warn : int key = create_key "cur_warn"

let time_limit : float key = create_key "time_limit"
let size_limit : float key = create_key "size_limit"

let logic_file : Logic.language file key = create_key "logic_file"
let response_file : Response.language file key = create_key "response_file"


(* State and locations *)
(* ************************************************************************* *)

let loc_input ?file st (loc : Dolmen.Std.Loc.loc) =
  (* sanity check to avoid pp_loc trying to read and/or print
     too much when printing the source code snippet) *)
  if loc.max_line_length >= 150 ||
     loc.stop_line - loc.start_line >= 100 then
    None
  else begin
    match get report_style st, (file : _ file option) with
    | _, None -> None
    | _, Some { source = `Stdin; _ } -> None
    | (Minimal | Regular), _ -> None
    | Contextual, Some { source = `File filename; dir; _ } ->
      let full_filename = Filename.concat dir filename in
      let input = Pp_loc.Input.file full_filename in
      Some input
    | Contextual, Some { source = `Raw (_, contents); _ } ->
      let input = Pp_loc.Input.string contents in
      Some input
  end

let pp_loc ?file st fmt o =
  match o with
  | None -> ()
  | Some loc ->
    if Dolmen.Std.Loc.is_dummy loc then ()
    else begin
      match loc_input ?file st loc with
      | None ->
        Format.fprintf fmt "%a:@ "
          Fmt.(styled `Bold @@ styled (`Fg (`Hi `White)) Dolmen.Std.Loc.fmt) loc
      | Some input ->
        let loc_start, loc_end = Dolmen.Std.Loc.lexing_positions loc in
        let locs = Pp_loc.Position.of_lexing loc_start, Pp_loc.Position.of_lexing loc_end in
        Format.fprintf fmt "%a:@ %a"
          Fmt.(styled `Bold @@ styled (`Fg (`Hi `White)) Dolmen.Std.Loc.fmt) loc
          (Pp_loc.pp ~max_lines:5 ~input) [locs]
    end

let flush st () =
  let aux _ = set cur_warn 0 st in
  let cur = get cur_warn st in
  let max = get max_warn st in
  if cur <= max then
    aux ()
  else
    match get report_style st with
    | Minimal ->
      Format.kfprintf aux Format.err_formatter
        "W:%d@." (cur - max)
    | Regular | Contextual ->
      Format.kfprintf aux Format.err_formatter
        ("@[<v>%a @[<hov>%s@ %d@ %swarnings@]@]@.")
        Fmt.(styled `Bold @@ styled (`Fg (`Hi `Magenta)) string) "Warning"
        (if max = 0 then "Counted" else "Plus")
        (cur - max) (if max = 0 then "" else "additional ")

let error ?file ?loc st error payload =
  let st = flush st () in
  let loc = Dolmen.Std.Misc.opt_map loc Dolmen.Std.Loc.full_loc in
  let aux _ = Code.exit (Report.Error.code error) in
  match get report_style st with
  | Minimal ->
    Format.kfprintf aux Format.err_formatter
      "E:%s@." (Report.Error.mnemonic error)
  | Regular | Contextual ->
    Format.kfprintf aux Format.err_formatter
      ("@[<v>%a%a @[<hov>%a@]%a@]@.")
      (pp_loc ?file st) loc
      Fmt.(styled `Bold @@ styled (`Fg (`Hi `Red)) string) "Error"
      Report.Error.print (error, payload)
      Report.Error.print_hints (error, payload)

let warn ?file ?loc st warn payload =
  let loc = Dolmen.Std.Misc.opt_map loc Dolmen.Std.Loc.full_loc in
  match Report.Conf.status (get reports st) warn with
  | Disabled -> st
  | Enabled ->
    let aux _ = update cur_warn ((+) 1) st in
    if get cur_warn st >= get max_warn st then
      aux st
    else
      begin match get report_style st with
        | Minimal ->
          Format.kfprintf aux Format.err_formatter
            "W:%s@." (Report.Warning.mnemonic warn)
        | Regular | Contextual ->
          Format.kfprintf aux Format.err_formatter
            ("@[<v>%a%a @[<hov>%a@]%a@]@.")
            (pp_loc ?file st) loc
            Fmt.(styled `Bold @@ styled (`Fg (`Hi `Magenta)) string) "Warning"
            Report.Warning.print (warn, payload)
            Report.Warning.print_hints (warn, payload)
      end
  | Fatal ->
    let aux _ = Code.exit (Report.Warning.code warn) in
    begin match get report_style st with
      | Minimal ->
        Format.kfprintf aux Format.err_formatter
          "F:%s@." (Report.Warning.mnemonic warn)
      | Regular | Contextual ->
        Format.kfprintf aux Format.err_formatter
          ("@[<v>%a%a @[<hov>%a@]%a@]@.")
          (pp_loc ?file st) loc
          Fmt.(styled `Bold @@ styled (`Fg (`Hi `Red)) string) "Fatal Warning"
          Report.Warning.print (warn, payload)
          Report.Warning.print_hints (warn, payload)
    end


