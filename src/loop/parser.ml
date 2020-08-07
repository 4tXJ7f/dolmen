
(* This file is free software, part of Dolmen. See file "LICENSE" for more details. *)

(* Pipe functor *)
(* ************************************************************************ *)

module Pipe
    (Expr : Expr_intf.S)
    (State : State_intf.Parser
     with type term := Expr.term)
= struct

  (* Module alias & Helper functions *)
  (* ************************************************************************ *)

  module S = Dolmen.Std.Statement

  (* Parsing *)
  (* ************************************************************************ *)

  let gen_finally (gen : 'a Gen.t) cl : 'a Gen.t =
    (* Register a finaliser for the original generator in case an exception is
       raised at some point in one of the pipes, which would prevent gen from
       reaching its end and thus prevent closing of the underlying file. *)
    let () = Gc.finalise_last cl gen in
    (* Return a new generator which wraps gen and calls the closing function
       once gen is finished. *)
    let aux () =
      match gen () with
      | Some _ as res -> res
      | None -> cl (); None
    in
    aux

  let wrap_parser g = fun st ->
    if State.is_interactive st then
      Format.printf "%s @?" (State.prelude st);
    State.start `Parsing;
    let ret = g () in
    State.stop `Parsing;
    ret

  let parse prelude st =
    State.start `Parsing;
    (* Parse the input *)
    let st', g =
      match State.input_source st with
      | `Stdin ->
        let lang, gen, _ = Logic.parse_input
            ?language:(State.input_lang st)
            (`Stdin (Logic.Smtlib2 `Latest))
        in
        State.set_lang st lang, gen
      | `Raw (filename, contents) ->
        let lang =
          match State.input_lang st with
          | Some l -> l
          | None ->
            let res, _, _ = Logic.of_filename filename in
            res
        in
        let lang, gen, cl = Logic.parse_input
            ~language:lang (`Raw (filename, lang, contents)) in
        State.set_lang st lang, gen_finally gen cl
      | `File f ->
        let s = Dolmen.Std.Statement.include_ f [] in
        (* Auto-detect input format *)
        let lang =
          match State.input_lang st with
          | Some l -> l
          | None ->
            let res, _, _ = Logic.of_filename f in
            res
        in
        (* Formats Dimacs and Tptp are descriptive and lack the emission
            of formal solve/prove instructions, so we need to add them. *)
        let s' =
          match lang with
          | Logic.Zf
          | Logic.ICNF
          | Logic.Smtlib2 _
          | Logic.Alt_ergo -> s
          | Logic.Dimacs
          | Logic.Tptp _ ->
            Dolmen.Std.Statement.pack [s; Dolmen.Std.Statement.prove ()]
        in
        State.set_lang st lang,
        (Gen.singleton s')
    in
    State.stop `Parsing;
    (* Wrap the resulting parser *)
    st', wrap_parser (Gen.append (Gen.of_list prelude) g)

  (* Expand dolmen statements *)
  (* ************************************************************************ *)

  let gen_of_list l =
    let l = ref l in
    (fun () -> match !l with
       | [] -> None
       | x :: r -> l := r; Some x
    )

  let expand (st, c) =
    State.start `Include;
    let ret = match c with
      | { S.descr = S.Pack l; _ } ->
        st, `Gen (true, Gen.of_list l)
      (* TODO: filter the statements by passing some stions *)
      | { S.descr = S.Include file; _ } ->
        let loc = c.loc in
        let language = State.input_lang st in
        let dir = State.input_dir st in
        begin
          match Logic.find ?language ~dir file with
          | None ->
            let loc = { Dolmen.Std.Loc.file = State.input_file_loc st; loc; } in
            State.file_not_found ~loc ~dir ~file
          | Some file ->
            let file_loc = Dolmen.Std.Loc.mk_file file in
            let st = State.set_input_file_loc st file_loc in
            begin match State.input_mode st with
              | None
              | Some `Incremental ->
                let lang, gen, cl = Logic.parse_input ?language (`File file) in
                let st = State.set_lang st lang in
                st, `Gen (true, gen_finally gen cl)
              | Some `Full ->
                let lang, l = Logic.parse_file ?language file in
                let st = State.set_lang st lang in
                st, `Gen (true, gen_of_list l)
            end
        end
      | _ -> (st, `Ok)
    in
    State.stop `Include;
    ret

(*
  (* Header & Automaton flow checking *)
  (* ************************************************************************ *)


  let first_mode ~check_headers lang =
    match (lang: Parser.language) with
    | Smtlib2 _ when check_headers -> Start { expect = Lang_Version; }
    | _ -> Assert

  let next_header lang current_header =
    match (lang: Parser.language) with
    | Smtlib2 _ ->
      begin match (current_header : header) with
        | Lang_Version -> Some Problem_Logic
        | Problem_Logic -> Some Problem_Source
        | Problem_Source -> Some Problem_License
        | Problem_License -> Some Problem_Category
        | Problem_Category -> Some Problem_Status
        | Problem_Status -> None
      end
    | _ -> None
*)


end

