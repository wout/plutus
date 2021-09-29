{ lib, pkgs, gitignore-nix }:
let
  cleanSrc = gitignore-nix.gitignoreSource ./.;

  replaceName = "sed s/\\$name/$name/g | sed s/\\$lname/$lname/g";

  # TODO rewrite this codegen utility with https://github.com/natefaubion/purescript-language-cst-parser
  newComponent = pkgs.writeShellScriptBin "new-component" ''
    name=$1
    lname="$(tr '[:upper:]' '[:lower:]' <<< $\{name:0:1})$\{name:1}"
    dir="src/Component/$1"
    file="$dir.purs"
    stateFile="$dir/State.purs"
    typesFile="$dir/Types.purs"
    internalTypesFile="$dir/Types/Internal.purs"
    viewFile="$dir/View.purs"
    mkdir $dir
    case $2 in
      page)
        dir="src/Page/$1"
        file="$dir.purs"
        stateFile="$dir/State.purs"
        typesFile="$dir/Types.purs"
        internalTypesFile="$dir/Types/Internal.purs"
        viewFile="$dir/View.purs"
        mkdir $dir/Types
        cat ${./templates/Page.purs.template} | ${replaceName} > $file
        cat ${./templates/Page/State.purs.template} | ${replaceName} > $stateFile
        cat ${./templates/Page/Types.purs.template} | ${replaceName} > $typesFile
        cat ${./templates/Page/Internal/Types.purs.template} | ${replaceName} > $internalTypesFile
        cat ${./templates/Page/View.purs.template} | ${replaceName} > $viewFile
        ;;
      stateful)
        mkdir $dir/Types
        cat ${./templates/Component/Stateful.purs.template} | ${replaceName} > $file
        cat ${./templates/Component/Stateful/State.purs.template} | ${replaceName} > $stateFile
        cat ${./templates/Component/Stateful/Types.purs.template} | ${replaceName} > $typesFile
        cat ${./templates/Component/Stateful/Internal/Types.purs.template} | ${replaceName} > $internalTypesFile
        cat ${./templates/Component/Stateful/View.purs.template} | ${replaceName} > $viewFile
        ;;
      *)
        cat ${./templates/Component/Stateless/Types.purs.template} | ${replaceName} > $typesFile
        cat ${./templates/Component/Stateless/View.purs.template} | ${replaceName} > $viewFile
        ;;
    esac
  '';
in
{
  inherit cleanSrc newComponent;
}
