{
  lib,
  fetchFromGitHub,
  rustPlatform,
  stdenv,
  installShellFiles,
}:

rustPlatform.buildRustPackage rec {
  pname = "swayhide";
  version = "v0.2.1";

  src = fetchFromGitHub {
    owner = "rehanzo";
    repo = pname;
    rev = version;
    sha256 = "sha256-ICDz3oDuXl/DAO4njoLJuv7hRXt76nGPPQlBVcc+hZo=";
  };

  cargoHash = "sha256-N3fuBnz8kKO5ncwbVx7ED4ufmXoTY6zNiW+8UcJigCA=";
  nativeBuildInputs = [ installShellFiles ];

  postInstall = ''
    installShellCompletion \
      --name ${pname} completions/swayhide.bash \
      --name ${pname}.fish completions/swayhide.fish \
      --name _${pname} completions/swayhide.zsh
  '';

  meta = with lib; {
    homepage = "https://github.com/rehanzo/swayhide";
    description = "Window swallower for swaywm";
    longDescription = ''
      `swayhide` hides the currently active terminal (by moving it to the scratchpad), 
      then it executes the supplied command.
    '';
    license = licenses.mit;
    maintainers = with maintainers; [ wildwestrom ];
    platforms = platforms.linux;
    mainProgram = "swayhide";
  };
}
