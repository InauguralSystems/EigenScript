{ pkgs }: {
  deps = [
    pkgs.python311
    pkgs.python311Packages.pip
    pkgs.python311Packages.flask
    pkgs.python311Packages.gunicorn
    pkgs.python311Packages.numpy
    pkgs.llvmPackages_15.llvm
    pkgs.clang_15
    pkgs.gcc
  ];
}
