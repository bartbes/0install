(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Parsing feeds *)

open General
open Support.Common
module Q = Support.Qdom
module U = Support.Utils
open Constants

module AttrMap = Support.Qdom.AttrMap

type importance =
  | Dep_essential       (* Must select a version of the dependency *)
  | Dep_recommended     (* Prefer to select a version, if possible *)
  | Dep_restricts       (* Just adds restrictions without expressing any opinion *)

type distro_retrieval_method = {
  distro_size : Int64.t option;
  distro_install_info : (string * string);        (* In some format meaningful to the distribution *)
}

type package_state =
  [ `installed
  | `uninstalled of distro_retrieval_method ]

type package_impl = {
  package_distro : string;
  mutable package_state : package_state;
}

type cache_impl = {
  digests : Manifest.digest list;
  retrieval_methods : Q.element list;
}

type impl_type =
  [ `cache_impl of cache_impl
  | `local_impl of filepath
  | `package_impl of package_impl ]

type restriction = < to_string : string; meets_restriction : impl_type implementation -> bool >

and binding = Q.element

and dependency = {
  dep_qdom : Q.element;
  dep_importance : importance;
  dep_iface: iface_uri;
  dep_restrictions: restriction list;
  dep_required_commands: string list;
  dep_if_os : string option;                (* The badly-named 'os' attribute *)
  dep_use : string option;                  (* Deprecated 'use' attribute *)
}

and command = {
  mutable command_qdom : Q.element;
  command_requires : dependency list;
  command_bindings : binding list;
}

and properties = {
  attrs : AttrMap.t;
  requires : dependency list;
  bindings : binding list;
  commands : command StringMap.t;
}

and +'a implementation = {
  qdom : Q.element;
  props : properties;
  stability : stability_level;
  os : string option;           (* Required OS; the first part of the 'arch' attribute. None for '*' *)
  machine : string option;      (* Required CPU; the second part of the 'arch' attribute. None for '*' *)
  parsed_version : Versions.parsed_version;
  impl_type : [< impl_type] as 'a;
}

type generic_implementation = impl_type implementation
type distro_implementation = [ `package_impl of package_impl ] implementation

let parse_stability ~from_user s =
  let if_from_user l =
    if from_user then l else raise_safe "Stability '%s' not allowed here" s in
  match s with
  | "insecure" -> Insecure
  | "buggy" -> Buggy
  | "developer" -> Developer
  | "testing" -> Testing
  | "stable" -> Stable
  | "packaged" -> if_from_user Packaged
  | "preferred" -> if_from_user Preferred
  | x -> raise_safe "Unknown stability level '%s'" x

let format_stability = function
  | Insecure -> "insecure"
  | Buggy -> "buggy"
  | Developer -> "developer"
  | Testing -> "testing"
  | Stable -> "stable"
  | Packaged -> "packaged"
  | Preferred -> "preferred"

type feed_overrides = {
  last_checked : float option;
  user_stability : stability_level StringMap.t;
}

type feed_type =
  | Feed_import             (* A <feed> import element inside a feed *)
  | User_registered         (* Added manually with "0install add-feed" : save to config *)
  | Site_packages           (* Found in the site-packages directory : save to config for older versions, but flag it *)
  | Distro_packages         (* Found in native_feeds : don't save *)

type feed_import = {
  feed_src : Feed_url.non_distro_feed;

  feed_os : string option;          (* All impls requires this OS *)
  feed_machine : string option;     (* All impls requires this CPU *)
  feed_langs : string list option;  (* No impls for languages not listed *)
  feed_type: feed_type;
}

type feed = {
  url : Feed_url.non_distro_feed;
  root : Q.element;
  name : string;
  implementations : 'a. ([> `cache_impl of cache_impl | `local_impl of Support.Common.filepath] as 'a) implementation StringMap.t;
  imported_feeds : feed_import list;

  (* The URI of the interface that replaced the one with the URI of this feed's URL.
     This is the value of the feed's <replaced-by interface'...'/> element. *)
  replacement : string option;

  package_implementations : (Q.element * properties) list;
}

let value_testing = "testing"

let make_command ?source_hint name ?(new_attr="path") path : command =
  let attrs = AttrMap.singleton "name" name
    |> AttrMap.add_no_ns new_attr path in
  let elem = ZI.make ?source_hint ~attrs "command" in
  {
    command_qdom = elem;
    command_requires = [];
    command_bindings = [];
  }

let make_distribtion_restriction distros =
  object
    method meets_restriction impl =
      ListLabels.exists (Str.split U.re_space distros) ~f:(fun distro ->
        match distro, impl.impl_type with
        | "0install", `package_impl _ -> false
        | "0install", `cache_impl _ -> true
        | "0install", `local_impl _ -> true
        | distro, `package_impl {package_distro;_} -> package_distro = distro
        | _ -> false
      )

    method to_string = "distribution:" ^ distros
  end

let get_attr_ex name impl =
  AttrMap.get_no_ns name impl.props.attrs |? lazy (Q.raise_elem "Missing '%s' attribute for " name impl.qdom)

let parse_version_element elem =
  let before = ZI.get_attribute_opt "before" elem in
  let not_before = ZI.get_attribute_opt "not-before" elem in
  let test = Versions.make_range_restriction not_before before in
  object
    method meets_restriction impl = test impl.parsed_version
    method to_string =
      match not_before, before with
      | None, None -> "no restriction!"
      | Some low, None -> "version " ^ low ^ ".."
      | None, Some high -> "version ..!" ^ high
      | Some low, Some high -> "version " ^ low ^ "..!" ^ high
  end

let make_impossible_restriction msg =
  object
    method meets_restriction _impl = false
    method to_string = Printf.sprintf "<impossible: %s>" msg
  end

let make_version_restriction expr =
  try
    let test = Versions.parse_expr expr in
    object
      method meets_restriction impl = test impl.parsed_version
      method to_string = "version " ^ expr
    end
  with Safe_exception (ex_msg, _) as ex ->
    let msg = Printf.sprintf "Can't parse version restriction '%s': %s" expr ex_msg in
    log_warning ~ex:ex "%s" msg;
    make_impossible_restriction msg

let parse_dep local_dir dep =
  let iface, dep =
    let raw_iface = ZI.get_attribute "interface" dep in
    if U.starts_with raw_iface "." then (
      match local_dir with
      | Some dir ->
          let iface = U.normpath @@ dir +/ raw_iface in
          (iface, {dep with Q.attrs = dep.Q.attrs |> Q.AttrMap.add_no_ns "interface" iface})
      | None ->
          raise_safe "Relative interface URI '%s' in non-local feed" raw_iface
    ) else (
      (raw_iface, dep)
    ) in

  let commands = ref StringSet.empty in
  let restrictions = dep |> ZI.filter_map (fun child ->
    match ZI.tag child with
    | Some "version" -> Some (parse_version_element child)
    | Some _ -> (
        match Binding.parse_binding child with
        | Some binding -> (
            match Binding.get_command binding with
            | None -> ()
            | Some name -> commands := StringSet.add name !commands
        )
        | None -> ()
    ); None
    | _ -> None
  ) in

  let restrictions = match ZI.get_attribute_opt "version" dep with
    | None -> restrictions
    | Some expr -> make_version_restriction expr :: restrictions
  in

  if ZI.tag dep = Some "runner" then (
    commands := StringSet.add (default "run" @@ ZI.get_attribute_opt "command" dep) !commands
  );

  let importance =
    if ZI.tag dep = Some "restricts" then Dep_restricts
    else (
      match ZI.get_attribute_opt FeedAttr.importance dep with
      | None | Some "essential" -> Dep_essential
      | _ -> Dep_recommended
    ) in

  let restrictions =
    match ZI.get_attribute_opt FeedAttr.distribution dep with
    | Some distros -> make_distribtion_restriction distros :: restrictions
    | None -> restrictions in

  {
    dep_qdom = dep;
    dep_iface = iface;
    dep_restrictions = restrictions;
    dep_required_commands = StringSet.elements !commands;
    dep_importance = importance;
    dep_use = ZI.get_attribute_opt FeedAttr.use dep;
    dep_if_os = ZI.get_attribute_opt FeedAttr.os dep;
  }

let parse_command local_dir elem : command =
  let deps = ref [] in
  let bindings = ref [] in

  elem |> ZI.iter (fun child ->
    match ZI.tag child with
    | Some "requires" | Some "restricts" | Some "runner" ->
        deps := parse_dep local_dir child :: !deps
    | Some b when Binding.is_binding b ->
        bindings := child :: !bindings
    | _ -> ()
  );

  {
    command_qdom = elem;
    command_requires = !deps;
    command_bindings = !bindings;
  }

let rec filter_if_0install_version node =
  match node.Q.attrs |> AttrMap.get_no_ns FeedAttr.if_0install_version with
  | Some expr when not (Versions.parse_expr expr About.parsed_version) -> None
  | Some _expr -> Some {
    node with Q.child_nodes = U.filter_map filter_if_0install_version node.Q.child_nodes;
    attrs = node.Q.attrs |> AttrMap.remove ("", FeedAttr.if_0install_version) 
  }
  | None -> Some {
    node with Q.child_nodes = U.filter_map filter_if_0install_version node.Q.child_nodes;
  }

let parse_implementations (system:system) url root local_dir =
  let implementations = ref StringMap.empty in
  let package_implementations = ref [] in

  let process_impl node (state:properties) =
    let s = ref state in

    let set_attr name value =
      let new_attrs = AttrMap.add_no_ns name value !s.attrs in
      s := {!s with attrs = new_attrs} in

    let get_required_attr name =
      AttrMap.get_no_ns name !s.attrs |? lazy (Q.raise_elem "Missing attribute '%s' on" name node) in

    let id = ZI.get_attribute "id" node in

    let () =
      match local_dir with
      | None ->
          if AttrMap.mem ("", FeedAttr.local_path) !s.attrs then
            Q.raise_elem "local-path in non-local feed! " node;
      | Some dir ->
          let use rel_path =
            if Filename.is_relative rel_path then
              set_attr FeedAttr.local_path @@ Support.Utils.abspath system @@ dir +/ rel_path
            else
              set_attr FeedAttr.local_path rel_path in
          match AttrMap.get_no_ns FeedAttr.local_path !s.attrs with
          | Some path -> use path
          | None ->
              if Support.Utils.starts_with id "/" || Support.Utils.starts_with id "." then
                use id in

    if StringMap.mem id !implementations then
      Q.raise_elem "Duplicate ID '%s' in:" id node;
    (* version-modifier *)
    AttrMap.get_no_ns FeedAttr.version_modifier !s.attrs
    |> if_some (fun modifier ->
        let real_version = get_required_attr FeedAttr.version ^ modifier in
        let new_attrs = AttrMap.add_no_ns FeedAttr.version real_version (AttrMap.remove ("", FeedAttr.version_modifier) !s.attrs) in
        s := {!s with attrs = new_attrs}
    );

    let get_prop key =
      AttrMap.get_no_ns key !s.attrs |? lazy (Q.raise_elem "Missing attribute '%s' on" key node) in

    let (os, machine) =
      try Arch.parse_arch @@ default "*-*" @@ AttrMap.get_no_ns "arch" !s.attrs
      with Safe_exception _ as ex -> reraise_with_context ex "... processing %s" (Q.show_with_loc node) in

    let stability =
      match AttrMap.get_no_ns FeedAttr.stability !s.attrs with
      | None -> Testing
      | Some s -> parse_stability ~from_user:false s in

    let impl_type =
      match AttrMap.get_no_ns FeedAttr.local_path !s.attrs with
      | Some local_path ->
          assert (local_dir <> None);
          `local_impl local_path
      | None ->
          let retrieval_methods = List.filter Recipe.is_retrieval_method node.Q.child_nodes in
          `cache_impl { digests = Stores.get_digests node; retrieval_methods; } in

    let impl = {
      qdom = node;
      props = {!s with requires = List.rev !s.requires};
      os;
      machine;
      stability;
      parsed_version = Versions.parse_version (get_prop FeedAttr.version);
      impl_type;
    } in
    implementations := StringMap.add id impl !implementations
  in

  let rec process_group state (group:Q.element) =
    group |> ZI.iter (fun item ->
      match ZI.tag item with
      | Some "group" | Some "implementation" | Some "package-implementation" -> (
          let s = ref state in
          (* We've found a group or implementation. Scan for dependencies,
             bindings and commands. Doing this here means that:
             - We can share the code for groups and implementations here.
             - The order doesn't matter, because these get processed first.
             A side-effect is that the document root cannot contain these. *)

          (* Upgrade main='...' to <command name='run' path='...'> etc *)
          let handle_old_command attr_name command_name =
            match ZI.get_attribute_opt attr_name item with
            | None -> ()
            | Some path ->
                let new_command = make_command ~source_hint:item command_name path in
                s := {!s with commands = StringMap.add command_name new_command !s.commands} in
          handle_old_command FeedAttr.main "run";
          handle_old_command FeedAttr.self_test "test";

          item.Q.attrs |> AttrMap.get (COMPILE_NS.ns, "command") |> if_some (fun command ->
            let new_command = make_command ~source_hint:item "compile" ~new_attr:"shell-command" command in
            s := {!s with commands = StringMap.add "compile" new_command !s.commands}
          );

          let new_bindings = ref [] in

          item |> ZI.iter (fun child ->
            match ZI.tag child with
            | Some "requires" | Some "restricts" ->
                let req = parse_dep local_dir child in
                s := {!s with requires = req :: !s.requires}
            | Some "command" ->
                let command_name = ZI.get_attribute "name" child in
                s := {!s with commands = StringMap.add command_name (parse_command local_dir child) !s.commands}
            | Some tag when Binding.is_binding tag ->
                new_bindings := child :: !new_bindings
            | _ -> ()
          );

          if !new_bindings <> [] then
            s := {!s with bindings = !s.bindings @ (List.rev !new_bindings)};

          let new_attrs = !s.attrs |> AttrMap.add_all item.Q.attrs in

          s := {!s with
            attrs = new_attrs;
            requires = !s.requires;
          };

          match ZI.tag item with
          | Some "group" -> process_group !s item
          | Some "implementation" -> process_impl item !s
          | Some "package-implementation" -> package_implementations := (item, !s) :: !package_implementations
          | _ -> assert false
      )
      | _ -> ()
    )
  in

  let root_attrs = AttrMap.empty
    |> AttrMap.add_no_ns FeedAttr.stability value_testing
    |> AttrMap.add_no_ns FeedAttr.from_feed url in

  (* 'main' on the <interface> (deprecated) *)
  let root_commands = match ZI.get_attribute_opt FeedAttr.main root with
    | None -> StringMap.empty
    | Some path ->
        let new_command = make_command ~source_hint:root "run" path in
        StringMap.singleton "run" new_command in

  let root_state = {
    attrs = root_attrs;
    bindings = [];
    commands = root_commands;
    requires = [];
  } in
  process_group root_state root;

  (!implementations, !package_implementations)

let parse system root feed_local_path =
  let root =
    match filter_if_0install_version root with
    | Some root -> root
    | None -> Q.raise_elem "Feed requires 0install version %s (we are %s):" (ZI.get_attribute FeedAttr.if_0install_version root) About.version root
  in

  let () = match ZI.tag root with
  | Some "interface" | Some "feed" -> ()
  | _ ->
      ZI.check_ns root;
      Q.raise_elem "Expected <interface>, not" root in

  let () = match ZI.get_attribute_opt "min-injector-version" root with
  | Some min_version when Versions.parse_version min_version > About.parsed_version ->
      Q.raise_elem "Feed requires 0install version %s or later (we are %s):" min_version About.version root
  | _ -> () in

  let url =
    match feed_local_path with
    | None -> ZI.get_attribute "uri" root
    | Some path -> path in

  let local_dir =
    match feed_local_path with
    | None -> None
    | Some path -> Some (Filename.dirname path) in

  (* For local feeds, make relative paths absolute. For cached feeds, reject paths. *)
  let normalise_url raw_url elem =
    if U.starts_with raw_url "http://" || U.starts_with raw_url "https://" then
      raw_url
    else (
      match local_dir with
      | Some dir -> U.normpath @@ dir +/ raw_url
      | None -> Q.raise_elem "Relative URI '%s' in non-local feed" raw_url elem
    ) in

  let parse_feed_import node =
    let (feed_os, feed_machine) = match ZI.get_attribute_opt "arch" node with
    | None -> (None, None)
    | Some arch -> Arch.parse_arch arch in

    let feed_langs = match ZI.get_attribute_opt FeedAttr.langs node with
    | None -> None
    | Some langs -> Some (Str.split U.re_space langs) in

    {
      feed_src = Feed_url.parse_non_distro @@ normalise_url (ZI.get_attribute FeedAttr.src node) node;
      feed_os;
      feed_machine;
      feed_langs;
      feed_type = Feed_import;
    } in

  let name = ref None in
  let replacement = ref None in
  let imported_feeds = ref [] in

  root |> ZI.iter (fun node ->
    match ZI.tag node with
    | Some "name" -> name := Some (Q.simple_content node)
    | Some "feed" -> imported_feeds := parse_feed_import node :: !imported_feeds
    | Some "replaced-by" ->
        if !replacement = None then
          replacement := Some (normalise_url (ZI.get_attribute FeedAttr.interface node) node)
        else
          Q.raise_elem "Multiple replacements!" node
    | _ -> ()
  );

  let implementations, package_implementations = parse_implementations system url root local_dir in

  {
    url = Feed_url.parse_non_distro url;
    name = (
      match !name with
      | None -> Q.raise_elem "Missing <name> in" root
      | Some name -> name
    );
    root;
    replacement = !replacement;
    implementations = implementations;
    package_implementations = package_implementations;
    imported_feeds = !imported_feeds;
  }

(* Get all the implementations (note: only sorted by ID) *)
let get_implementations feed =
  StringMap.map_bindings (fun _k impl -> impl) feed.implementations

let is_source impl = impl.machine = Some "src"

let get_command_opt command_name impl = StringMap.find command_name impl.props.commands

let get_command_ex command_name impl : command =
  StringMap.find command_name impl.props.commands |? lazy (Q.raise_elem "Command '%s' not found in" command_name impl.qdom)

(** Load per-feed extra data (last-checked time and preferred stability.
    Probably we should use a simple timestamp file for the last-checked time and attach
    the stability ratings to the interface, not the feed. *)
let load_feed_overrides config feed_url =
  let open Support.Basedir in
  let url = Feed_url.format_url feed_url in
  match load_first config.system (config_site +/ config_prog +/ "feeds" +/ Escape.pretty url) config.basedirs.config with
  | None -> { last_checked = None; user_stability = StringMap.empty }
  | Some path ->
      let root = Q.parse_file config.system path in

      let last_checked =
        match ZI.get_attribute_opt "last-checked" root with
        | None -> None
        | Some time -> Some (float_of_string time) in

      let stability = ref StringMap.empty in

      root |> ZI.iter ~name:"implementation" (fun impl ->
        let id = ZI.get_attribute "id" impl in
        match ZI.get_attribute_opt FeedConfigAttr.user_stability impl with
        | None -> ()
        | Some s -> stability := StringMap.add id (parse_stability ~from_user:true s) !stability
      );

      { last_checked; user_stability = !stability; }

let save_feed_overrides config feed_url overrides =
  let module B = Support.Basedir in
  let {last_checked; user_stability} = overrides in
  let feeds = B.save_path config.system (config_site +/ config_prog +/ "feeds") config.basedirs.B.config in

  let attrs =
    match last_checked with
    | None -> AttrMap.empty
    | Some last_checked -> AttrMap.singleton "last-checked" (Printf.sprintf "%.0f" last_checked) in
  let child_nodes = user_stability |> StringMap.map_bindings (fun id stability ->
    ZI.make "implementation" ~attrs:(
      AttrMap.singleton FeedAttr.id id
      |> AttrMap.add_no_ns FeedConfigAttr.user_stability (format_stability stability)
    )
  ) in
  let root = ZI.make ~attrs ~child_nodes "feed-preferences" in
  let url = Feed_url.format_url feed_url in
  feeds +/ Escape.pretty url |> config.system#atomic_write [Open_wronly; Open_binary] ~mode:0o644 (fun ch ->
    Q.output (`Channel ch |> Xmlm.make_output) root;
  )

let update_last_checked_time config url =
  let overrides = load_feed_overrides config url in
  save_feed_overrides config url {overrides with last_checked = Some config.system#time}

(** The list of languages provided by this implementation. *)
let get_langs impl =
  let langs =
    match AttrMap.get_no_ns "langs" impl.props.attrs with
    | Some langs -> Str.split U.re_space langs
    | None -> ["en"] in
  Support.Utils.filter_map Support.Locale.parse_lang langs

(** Is this implementation in the cache? *)
let is_available_locally config impl =
  match impl.impl_type with
  | `package_impl {package_state;_} -> package_state = `installed
  | `local_impl path -> config.system#file_exists path
  | `cache_impl {digests;_} ->
      match Stores.lookup_maybe config.system digests config.stores with
      | None -> false
      | Some _path -> true

let is_retrievable_without_network cache_impl =
  let ok_without_network elem =
    match Recipe.parse_retrieval_method elem with
    | Some recipe -> not @@ Recipe.recipe_requires_network recipe
    | None -> false in
  List.exists ok_without_network cache_impl.retrieval_methods

let get_id impl =
  let feed_url = get_attr_ex FeedAttr.from_feed impl in
  Feed_url.({feed = Feed_url.parse feed_url; id = get_attr_ex FeedAttr.id impl})

let get_text tag langs feed =
  let best = ref None in
  feed.root |> ZI.iter ~name:tag (fun elem ->
    let new_score = elem.Q.attrs |> AttrMap.get (xml_ns, FeedAttr.lang) |> Support.Locale.score_lang langs in
    match !best with
    | Some (_old_summary, old_score) when new_score <= old_score -> ()
    | _ -> best := Some (elem.Q.last_text_inside, new_score)
  );
  match !best with
  | None -> None
  | Some (summary, _score) -> Some summary

let get_summary = get_text "summary"
let get_description = get_text "description"

let get_feed_targets feed =
  feed.root |> ZI.map ~name:"feed-for" (ZI.get_attribute FeedAttr.interface)

let make_user_import feed_src = {
  feed_src = (feed_src :> Feed_url.non_distro_feed);
  feed_os = None;
  feed_machine = None;
  feed_langs = None;
  feed_type = User_registered;
}

let get_category feed =
  try
    let elem = feed.root.Q.child_nodes |> List.find (fun node -> ZI.tag node = Some "category") in
    Some elem.Q.last_text_inside
  with Not_found -> None

let needs_terminal feed =
  feed.root.Q.child_nodes |> List.exists (fun node -> ZI.tag node = Some "needs-terminal")
