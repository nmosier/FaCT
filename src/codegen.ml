open Util
open Pos
open Err
open Tast
open Llvm
open Pseudocode

(* let built : Llvm.llvalue -> unit = ignore *)

let built visit bty llval =
  match bty with
  | None -> ()
  | Some bty -> visit#set_taint_metadata bty llval

let label_to_idx lbl' = match lbl' with
  | Tast.Public -> 1
  | Tast.Secret -> 0;;

class vardec_collector m =
  object (visit)
    inherit Tastmap.tast_visitor m as super
    val mutable _vars : (var_name * base_type) list = []

    method _vars () =
      List.rev _vars

    method param param =
      begin
        match param.data with
          | Param (x,bty) ->
            _vars <- (x,bty) :: _vars
      end; super#param param

    method block_only (block,next) =
      begin
        match block.data with
          | RangeFor (x,bty,_,_,_)
          | ArrayFor (x,bty,_,_) ->
            _vars <- (x,bty) :: _vars
          | _ -> ()
      end; super#block_only (block,next)

    method stm stm =
      begin
        match stm.data with
          | VarDec (x,bty,_)
          | FnCall (x,bty,_,_) ->
            _vars <- (x,bty) :: _vars
          | _ -> ()
      end; super#stm stm

  end

let collect_vardecs fdec =
  let m = Module([],[fdec],{fmap=[]}) in
  let visit = new vardec_collector m in
    visit#fact_module () |> ignore;
    visit#_vars ()

class codegen no_inline_asm llctx llmod m =
  object (visit)
    val all_vars_indirect = false

    val _get_intrinsic = Intrinsics.make_stuff llctx llmod
    val _select_of_choice = fun n -> Intrinsics.(if no_inline_asm then SelectXor n else select_of_choice n)
    val _cmov_of_choice = fun n -> Intrinsics.(if no_inline_asm then CmovXor n else cmov_of_choice n)
    val _b : Llvm.llbuilder = Llvm.builder llctx

    val _sdecs : (struct_name * (var_name * (int * base_type)) list) mlist = ref []

    val _venv : (var_name * llvalue) mlist = ref []
    val _fenv : (fun_name * llvalue) mlist = ref []
    val _senv : (struct_name * lltype) mlist = ref []

    val i1ty = i1_type llctx
    val i8ty = i8_type llctx
    val i16ty = i16_type llctx
    val i32ty = i32_type llctx
    val i64ty = i64_type llctx
    val i128ty = integer_type llctx 128
    val voidty = void_type llctx
    val noinline = create_enum_attr llctx "noinline" 0L
    val alwaysinline = create_enum_attr llctx "alwaysinline" 0L

    method _get x =
      let res = mlist_find ~equal:Tast_util.vequal !_venv x in
        match res with
          | Some llval -> llval
          | None -> raise @@ cerr x.pos "couldn't find '%s'" x.data

    method _fget fn =
      let res = mlist_find ~equal:Tast_util.vequal !_fenv fn in
        match res with
          | Some llfn -> llfn
          | None -> raise @@ cerr fn.pos
                               "unknown function: '%s'" fn.data

    method _sget s =
      let res = mlist_find ~equal:Tast_util.vequal !_senv s in
        match res with
          | Some llty -> llty
          | None -> raise @@ cerr s.pos
                               "unknown type: '%s'" s.data

    method _get_field bty fld =
      let p = bty.pos in
      let sname = match bty.data with
        | Ref ({data=Struct s},_) -> s
        | _ -> raise @@ cerr p "expected a struct, got %s" (ps#bty bty) in
      let fields = match  mlist_find ~equal:Tast_util.vequal !_sdecs sname with
        | Some fields -> fields
        | None -> raise @@ err p in
      let i,bty = match mlist_find ~equal:Tast_util.vequal fields fld with
        | Some entry -> entry
        | None -> raise @@ err p in
        i,bty

    method bty {pos=p;data} =
      match data with
        | Bool _ -> i1ty
        | UInt (s,_) | Int (s,_) -> integer_type llctx s
        | Ref (bty,_) -> pointer_type (visit#bty bty)
        | Arr ({data=Ref (bty,_)},_,_) -> pointer_type (visit#bty bty)
        | UVec (s,n,_) -> vector_type (integer_type llctx s) n
        | Struct s -> visit#_sget s
        | String -> raise @@ err p

    method fact_module () =
      let Module (sdecs,fdecs,minfo) = m in
      let _ = List.map visit#sdec sdecs in
      let _ = List.map visit#fdec (List.rev fdecs) in
        ()

    method sdec {pos=p;data} =
      let StructDef (name, fields) = data in
      let field_entries = List.mapi
                            (fun i {data=Field(x,bty)} ->
                               (x, (i, bty)))
                            fields in
      mlist_push (name, field_entries) _sdecs;
        let llfields = List.map visit#field fields in
        let justthetypes = List.map (fun (_,bty) -> bty) llfields in
        let llsty = named_struct_type llctx name.data in
          struct_set_body llsty (Array.of_list justthetypes) false;
          mlist_push (name,llsty) _senv;

    method field {pos=p;data} =
      let Field (x,bty) = data in
      let llbty = visit#bty_for_struct bty in
        (x,llbty)

    method bty_for_struct {pos=p;data} =
      match data with
        | Bool _ -> i8ty
        | UInt (s,_) | Int (s,_) -> integer_type llctx s
        | Ref (bty,_) -> pointer_type (visit#bty bty)
        | Arr ({data=Ref (bty,_)},lexpr,_) -> array_type (visit#bty bty) (visit#lexpr_for_struct lexpr)
        | UVec (s,n,_) -> vector_type (integer_type llctx s) n
        | Struct s -> visit#_sget s
        | String -> raise @@ err p

    method lexpr_for_struct {pos=p;data} =
      match data with
        | LIntLiteral n -> n
        | LDynamic x ->
          raise @@ cerr p "dependent arrays not yet implemented"

    method _prototype name rt params =
      let param_types = List.map visit#param params |> Array.of_list in
      let ret_ty =
        match rt with
          | Some bty -> visit#bty bty
          | None -> voidty in
      function_type ret_ty param_types

    method fdec ({pos=p;data} as fdec) =
      match data with
        | FunDec(name,fnattr,rt,params,body) ->
          let ft = visit#_prototype name rt params in
          let llfn = define_function name.data ft llmod in
            mlist_push (name,llfn) _fenv;
            if not fnattr.export then
              set_linkage Internal llfn;
            begin
              match fnattr.inline with
                | Always ->
                  add_function_attr llfn alwaysinline Function
                | Never ->
                  add_function_attr llfn noinline Function
                | _ -> ()
            end;
            let bb = entry_block llfn in
              position_at_end bb _b;
              let vars = collect_vardecs fdec in
              if all_vars_indirect then
                  begin
                    List.iter
                      (fun (x,bty) ->
                         let llty = visit#bty bty in
                         let stackloc = build_alloca llty x.data _b in
                         mlist_push (x,stackloc) _venv)
                      vars;
                    Array.iter2
                      (fun llparam {data=Param(x,bty)} ->
                        let stackloc = visit#_get x in
                        build_store llparam stackloc _b |> ignore)
                      (Llvm.params llfn)
                      (Array.of_list params);
                  end
                else
                  begin
                    Array.iter2
                      (fun llparam {data=Param(x,_)} ->
                         set_value_name x.data llparam;
                         mlist_push (x,llparam) _venv)
                      (Llvm.params llfn)
                      (Array.of_list params);
                  end;
              visit#block body |> ignore;
              (*
              (* Set insertion point right before terminator *)
              let After last_inst = Llvm.instr_end (Llvm.entry_block llfn) in
              assert (Llvm.is_terminator last_inst);
              Llvm.position_before last_inst _b;
              Array.iter2 (fun llparam {data=Param(_,bty)} ->
                  (* Llvm.position_at_end (Llvm.entry_block llfn) _b; *)
                  visit#set_taint_metadata2 bty llparam
                )
                (Llvm.params llfn)
                (Array.of_list params);
              Llvm.dump_value llfn;
               *)
              (* Llvm.instr_end
               *)
              llfn
        | CExtern (name,fnattr,rt,params) ->
          let ft = visit#_prototype name rt params in
          let llfn = declare_function name.data ft llmod in
            mlist_push (name,llfn) _fenv;
            llfn
        | StdlibFn (code,fnattr,rt,params) ->
          let name = Cstdlib.name_of code in
          let llfn = Cstdlib.llvm_for visit#_sget llctx llmod code in
            mlist_push (name,llfn) _fenv;
            llfn

    method param {pos=p;data} =
      match data with
        | Param (x,bty) ->
          visit#bty bty

    method block ({pos=p;data},next) =
      begin
        match data with
          | Scope blk ->
            visit#block blk |> ignore
          | ListOfStuff stms ->
            List.iter visit#stm stms
          | If (cond,thens,elses) ->
            let llcond = visit#expr cond in
            let curfn = insertion_block _b |> block_parent in
            let then_bb = append_block llctx "" curfn in
            let else_bb = append_block llctx "" curfn in
            let merge_bb = append_block llctx "" curfn in
              build_cond_br llcond then_bb else_bb _b |> ignore;
              position_at_end then_bb _b;
              if visit#block thens then
                build_br merge_bb _b |> ignore;
              position_at_end else_bb _b;
              if visit#block elses then
                build_br merge_bb _b |> ignore;
              position_at_end merge_bb _b
          | RangeFor (x,bty,e1,e2,blk) ->
            let lle1 = visit#expr e1 in
            let lle2 = visit#expr e2 in
            let llbty = visit#bty bty in
            let pre_bb = insertion_block _b in
            let curfn = block_parent pre_bb in
            let check_bb = append_block llctx "" curfn in
            let loop_bb = append_block llctx "" curfn in
            let iter_bb = append_block llctx "" curfn in
            let post_bb = append_block llctx "" curfn in
            let cmp = if Tast_util.is_signed bty then Icmp.Slt else Icmp.Ult in

            let load_iter loc =
              if all_vars_indirect
              then let load = build_load loc "" _b in
                   built visit (Some bty) load;
                   load
              else loc
            in

            let store_iter llval loc =
              if all_vars_indirect
              then build_store llval loc _b |> ignore
              else add_incoming (llval, insertion_block _b) loc
            in

              position_at_end check_bb _b;
              let iterloc =
                if all_vars_indirect
                then visit#_get x
                else (let loc = build_empty_phi llbty x.data _b in
                        mlist_push (x,loc) _venv; loc) in
              let iter = load_iter iterloc in
              let check = build_icmp cmp iter lle2 "" _b in
                build_cond_br check loop_bb post_bb  _b |> ignore;

                position_at_end pre_bb _b;
                store_iter lle1 iterloc;
                build_br check_bb _b |> ignore;

                position_at_end loop_bb _b;
                if visit#block blk then
                  build_br iter_bb _b |> ignore;

                position_at_end iter_bb _b;
                let iter = load_iter iterloc in
                let one = const_int (type_of iter) 1 in
                let add = build_add iter one "" _b in
                  store_iter add iterloc;
                  build_br check_bb _b |> ignore;

                  position_at_end post_bb _b
          | ArrayFor (x,bty,e,blk) ->
            let lle = visit#expr e in
            let len = Tast_util.(length_of (type_of e)) in
            let lllen = visit#lexpr len in
            let pre_bb = insertion_block _b in
            let curfn = block_parent pre_bb in
            let check_bb = append_block llctx "" curfn in
            let loop_bb = append_block llctx "" curfn in
            let iter_bb = append_block llctx "" curfn in
            let post_bb = append_block llctx "" curfn in
              if all_vars_indirect then
                let xloc = visit#_get x in
                let iterloc = build_alloca i64ty "" _b in
                  build_store (const_null i64ty) iterloc _b;
                  build_br check_bb _b;

                  position_at_end check_bb _b;
                  let iter = build_load iterloc "" _b in
                  built visit (Some bty) iter;
                  let check = build_icmp Icmp.Ult iter lllen "" _b in
                    build_cond_br check loop_bb post_bb _b;

                    position_at_end loop_bb _b;
                    let iter = build_load iterloc "" _b in
                    built visit (Some bty) iter;
                    let gep = build_gep lle [| iter |] "" _b in
                    let load = build_load gep "" _b in
                    built visit (Some (Tast_util.type_of e)) load;
                      build_store load xloc _b;
                      if visit#block blk then
                        build_br iter_bb _b |> ignore;

                    position_at_end iter_bb _b;
                    let iter = build_load iterloc "" _b in
                    built visit (Some bty) iter;
                    let one = const_int (type_of iter) 1 in
                    let add = build_add iter one "" _b in
                      build_store add iterloc _b;
                      build_br check_bb _b;
                      position_at_end post_bb _b
              else
                begin
                  build_br check_bb _b;
                  position_at_end check_bb _b;
                  let zero = const_null i64ty in
                  let iter = build_phi [ (zero, pre_bb) ] "" _b in
                  let check = build_icmp Icmp.Ult iter lllen "" _b in
                    build_cond_br check loop_bb post_bb  _b;

                    position_at_end loop_bb _b;
                    let gep = build_gep lle [| iter |] "" _b in
                    let load = build_load gep "" _b in
                    built visit (Some (Tast_util.type_of e)) load;
                      mlist_push (x,load) _venv;
                      if visit#block blk then
                        build_br iter_bb _b |> ignore;

                      position_at_end iter_bb _b;
                      let one = const_int (type_of iter) 1 in
                      let add = build_add iter one "" _b in
                        add_incoming (add, iter_bb) iter;
                        build_br check_bb _b;

                        position_at_end post_bb _b
                end
      end;
      visit#next next

    method next {pos=p;data} =
      match data with
        | Block blk ->
          (*let curfn = insertion_block _b |> block_parent in
          let bb = append_block llctx "" curfn in
            position_at_end bb _b;*)
            visit#block blk
        | Return e ->
          let lle = visit#expr e in
          build_ret lle _b;
          false
        | VoidReturn -> build_ret_void _b;
          false
        | End -> true

    method stm {pos=p;data} =
      match data with
        | VarDec (x,bty,e) ->
          let lle = visit#expr e in
            if all_vars_indirect then
              let loc = visit#_get x in
                build_store lle loc _b |> ignore
            else
              begin
                set_value_name x.data lle;
                mlist_push (x,lle) _venv
              end
        | FnCall (x,bty,fn,args) ->
          let llfn = visit#_fget fn in
          let llargs = List.map visit#expr args |> Array.of_list in
          let call = build_call llfn llargs "" _b in
            if all_vars_indirect then
              let loc = visit#_get x in
                build_store call loc _b |> ignore
            else
              begin
                set_value_name x.data call;
                mlist_push (x,call) _venv
              end
        | VoidFnCall (fn,args) ->
          let llfn = visit#_fget fn in
          let llargs = List.map visit#expr args |> Array.of_list in
          build_call llfn llargs "" _b |> ignore
        | Assign (e1,e2) ->
          let lle1 = visit#expr e1 in
          let lle2 = visit#expr e2 in
          build_store lle2 lle1 _b |> ignore
        | Cmov (e1,cond,e2) ->
          let lle1 = visit#expr e1 in
          let lle2 = visit#expr e2 in
          let llcond = visit#expr cond in
          let cmov = _get_intrinsic (_cmov_of_choice (integer_bitwidth (type_of lle2))) in
          let orig = build_load lle1 "" _b in
          built visit (Some (Tast_util.type_of e1)) orig;
          let result = build_call cmov [| llcond; lle2; orig |] "" _b in
            build_store result lle1 _b |> ignore
        | Assume e -> ()

    method expr ({pos=p;data},bty) =
      let llbty = visit#bty bty in
      let llres = match data with
          | True -> const_all_ones i1ty
          | False -> const_null i1ty
          | IntLiteral n -> const_int llbty n
          | Variable x ->
            if all_vars_indirect then
              let loc = visit#_get x in
              build_load loc "" _b
            else
              visit#_get x
          | Cast (castty,e) ->
            let lle = visit#expr e in
            let llcastty = visit#bty castty in
            let oldsize = integer_bitwidth (type_of lle) in
            let newsize = integer_bitwidth llcastty in
            let build_cast =
              if newsize < oldsize then
                build_trunc
              else if newsize > oldsize then
                if Tast_util.(is_signed (Tast_util.type_of e))
                then build_sext
                else build_zext
              else (fun lle _ _ _ -> lle) in
              build_cast lle llcastty "" _b
          | UnOp (op,e) ->
            let lle = visit#expr e in
            visit#unop op lle 
          | BinOp (op,e1,e2) ->
            let lle1 = visit#expr e1 in
            let lle2 = visit#expr e2 in
            let e1ty = Tast_util.type_of e1 in
            let is_signed = Tast_util.(not (is_bool e1ty) && is_signed e1ty) in
            visit#binop op is_signed lle1 lle2
          | TernOp (e1,e2,e3) ->
            let lle1 = visit#expr e1 in
            let lle2 = visit#expr e2 in
            let lle3 = visit#expr e3 in
            build_select lle1 lle2 lle3 "" _b
          | Select (e1,e2,e3) ->
            let lle1 = visit#expr e1 in
            let lle2 = visit#expr e2 in
            let lle3 = visit#expr e3 in
            let select = _get_intrinsic (_select_of_choice (integer_bitwidth llbty)) in
            build_call select [| lle1; lle2; lle3 |] "" _b
          | Declassify e
          | Classify e -> visit#expr e
          | Enref e ->
             let lbl = Tast_util.label_of bty in
             let lbl_idx = (match lbl.data with
                            | Tast.Public -> 1
                            | Tast.Secret -> 0) in
             let lle = visit#expr e in
             let lle_bty = type_of lle in
             let stackloc = build_alloca lle_bty "" _b in
             build_store lle stackloc _b;
             stackloc
          | Deref e ->
            let lle = visit#expr e in
            build_load lle "" _b
          | ArrayGet (e,lexpr) ->
            let lle = visit#expr e in
            let lllexpr = visit#lexpr lexpr in
            build_gep lle [| lllexpr |] "" _b
          | ArrayLit es ->
            let lles = List.map visit#expr es in
            let Some el_ty = Tast_util.element_type bty in
            let len = Tast_util.length_of bty in
            let llelty = visit#bty el_ty in
            let lllen = visit#lexpr len in
            let newarr = build_array_alloca llelty lllen "" _b in
              List.iteri
                (fun i lle ->
                   let cell = build_gep newarr [| const_int i64ty i |] "" _b in
                     build_store lle cell _b |> ignore)
                lles;
              newarr
          | ArrayZeros len ->
            let Some el_ty = Tast_util.element_type bty in
            let llelty = visit#bty el_ty in
            let lllen = visit#lexpr len in
            let newarr = build_array_alloca llelty lllen "" _b in
            let memset = _get_intrinsic (Memset (integer_bitwidth llelty)) in
              build_call memset [| newarr; (const_null i8ty); lllen |] "" _b;
              newarr
          | ArrayCopy e ->
            let Some el_ty = Tast_util.element_type bty in
            let len = Tast_util.length_of bty in
            let lle = visit#expr e in
            let llelty = visit#bty el_ty in
            let lllen = visit#lexpr len in
            let newarr = build_array_alloca llelty lllen "" _b in
            let memcpy = _get_intrinsic (Memcpy (integer_bitwidth llelty)) in
              build_call memcpy [| newarr; lle; lllen |] "" _b;
              newarr
          | ArrayView (e,start,len) ->
            let lle = visit#expr e in
            let llstart = visit#lexpr start in
              build_gep lle [| llstart |] "" _b
          | VectorLit ns ->
            let llelty = element_type llbty in
            let llns = List.map (const_int llelty) ns in
              const_vector (Array.of_list llns)
          | Shuffle (e,ns) ->
            let lle = visit#expr e in
              begin
                match ns with
                  | [n] ->
                    let lln = const_int llbty n in
                      build_extractelement lle lln "" _b
                  | _ ->
                    let llelty = element_type llbty in
                    let llns = List.map (const_int llelty) ns |> Array.of_list |> const_vector in
                    let na = undef (type_of lle) in
                      build_shufflevector lle na llns "" _b
              end
          | StructLit entries ->
            let space = build_alloca (element_type llbty) "" _b in
              List.iter
                (fun (fld,e) ->
                   let i,fldty = visit#_get_field bty fld in
                   let lle = visit#expr e in
                   let loc = build_struct_gep space i "" _b in
                     match fldty.data with
                       | Bool _
                       | UInt _
                       | Int _ ->
                         build_store lle loc _b |> ignore
                       | Arr _ ->
                         let underlying_ty = lle |> type_of |> element_type in
                         let pty = pointer_type underlying_ty in
                         let casted = build_bitcast loc pty "" _b in
                         let len = Tast_util.(length_of (type_of e)) in
                         let lllen = visit#lexpr len in
                         let memcpy = _get_intrinsic (Memcpy (integer_bitwidth underlying_ty)) in
                           build_call memcpy [| casted; lle; lllen |] "" _b |> ignore
                )
                entries;
              space
          | StructGet (e,fld) ->
            let ety = Tast_util.type_of e in
            let lle = visit#expr e in
            let i,_ = visit#_get_field ety fld in
            let res = build_struct_gep lle i "" _b in
            let underlying_ty = type_of res |> element_type in
              begin
                match classify_type underlying_ty with
                  | TypeKind.Pointer ->
                     build_load res "" _b
                  | TypeKind.Array ->
                    let pty = underlying_ty |> element_type |> pointer_type in
                    build_bitcast res pty "" _b
                  | _ -> res
              end
          | _ -> raise @@ cerr p "unimplemented in codegen: %s" (show_expr' data) in
      built visit (Some bty) llres;
      llres

    method lexpr {pos=p;data} =
      match data with
        | LIntLiteral n -> const_int i64ty n
        | LDynamic x ->
          if all_vars_indirect then
            let loc = visit#_get x in
            build_load loc "" _b (* TODO: built *)
          else
            visit#_get x

    method unop op lle =
      let build_unop =
        match op with
          | Ast.Neg -> build_neg
          | Ast.LogicalNot -> build_not
          | Ast.BitwiseNot -> build_not
      in
        build_unop lle "" _b

    method binop op is_signed lle1 lle2 =
      let build_binop =
        match op with
          | Ast.Plus -> build_add
          | Ast.Minus -> build_sub
          | Ast.Multiply -> build_mul
          | Ast.Divide -> if is_signed then build_sdiv else build_udiv
          | Ast.Modulo -> if is_signed then build_srem else build_urem
          | Ast.Equal -> build_icmp Icmp.Eq
          | Ast.NEqual -> build_icmp Icmp.Ne
          | Ast.GT -> build_icmp (if is_signed then Icmp.Sgt else Icmp.Ugt)
          | Ast.GTE -> build_icmp (if is_signed then Icmp.Sge else Icmp.Uge)
          | Ast.LT -> build_icmp (if is_signed then Icmp.Slt else Icmp.Ult)
          | Ast.LTE -> build_icmp (if is_signed then Icmp.Sle else Icmp.Ule)
          | Ast.LogicalAnd -> build_and
          | Ast.LogicalOr -> build_or
          | Ast.BitwiseAnd -> build_and
          | Ast.BitwiseOr -> build_or
          | Ast.BitwiseXor -> build_xor
          | Ast.LeftShift -> build_shl
          | Ast.RightShift -> if is_signed then build_ashr else build_lshr
          | Ast.LeftRotate ->
            let rotl = _get_intrinsic (Rotl (integer_bitwidth (type_of lle1))) in
              (fun a b -> build_call rotl [| a; b |])
          | Ast.RightRotate ->
            let rotr = _get_intrinsic (Rotr (integer_bitwidth (type_of lle1))) in
              (fun a b -> build_call rotr [| a; b |])
      in
      build_binop lle1 lle2 "" _b


    (*
    method set_taint_metadata bty llval =
      let mdkind = mdkind_id llctx "taint" in
      let mdvals = get_named_metadata llmod "taint" in
      let lblidx = label_to_idx (Tast_util.label_of bty).data in
      print_string "lblidx "; print_int lblidx; print_newline ();
      print_int (Array.length mdvals); print_newline ();
      let mdval = Array.get mdvals lblidx in
      set_metadata llval mdkind mdval;
      ()
     *)

    method set_taint_metadata bty llval =
      match Llvm.type_of llval |> Llvm.classify_type with
      | Integer -> 
         let lbl = (Tast_util.label_of bty).data in
         let lblstr = match lbl with
           | Secret -> "secret"
           | Public -> "public" in
         let mdkind = Llvm.mdkind_id llctx "taint" in
         let mdnode = Llvm.mdstring llctx lblstr in
         set_metadata llval mdkind mdnode;
         ()
      | _ -> ()

    (*
    method get_taint_intrinsic_str bty =
      match (Llvm.classify_type bty) with
      | Void -> None
      | Integer -> Some (Printf.sprintf "llvm.annotation.i%d" (integer_bitwidth bty))
      | Pointer -> 
     *)

    method set_taint_metadata2 bty llval =
      let lbl = (Tast_util.label_of bty).data in
      let lblstr = match lbl with
        | Secret -> "secret"
        | Public -> "public" in
      (*
      let mdkind = Llvm.mdkind_id llctx "taint" in
      let mdnode = Llvm.mdstring llctx lblstr in
       *)
      let llty = Llvm.type_of llval in
      match (Llvm.classify_type llty) with
      | Integer ->
         (* let intrinsic_str = Printf.sprintf "llvm.annotation.i%d" (integer_bitwidth llty) in *)
         let intrinsic_str = Printf.sprintf "fact.%s.i%d" lblstr (integer_bitwidth llty) in
         let intrinsic_ty = Llvm.function_type (Llvm.void_type llctx) [| llty |] in
         let intrinsic_fn = Llvm.declare_function intrinsic_str intrinsic_ty llmod in
         build_call intrinsic_fn [| llval |] "" _b;
         ()
      | _ -> ()

    
  end

let codegen no_inline_asm m =
  let llctx = Llvm.create_context () in
  let llmod = Llvm.create_module llctx "Module" in
  let taint_secret = const_string llctx "secret" in
  let taint_public = const_string llctx "public" in
  let taint_arr = Array.of_list [taint_secret; taint_public; taint_public] in
  print_string "taint_arr len is "; print_int (Array.length taint_arr); print_newline ();
  let mdtaint = mdnode llctx taint_arr in
  add_named_metadata_operand llmod "taint" mdtaint;
  let visit = new codegen no_inline_asm llctx llmod m in
    visit#fact_module (); llctx, llmod
