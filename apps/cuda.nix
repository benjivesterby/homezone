{ config, pkgs, lib, ... }:

let
  unpatched-nvidia-driver = (config.hardware.nvidia.package.overrideAttrs (oldAttrs: {
    builder = ../overlays/nvidia-builder.sh;
  }));

  nvidia-pkgs = with pkgs; [
    (lib.getBin glibc) # for ldconfig in preStart
    (lib.getBin unpatched-nvidia-driver)
    nvidia-k3s
    cudaPackages.fabricmanager
  ];

  runtime-config = pkgs.runCommandNoCC "config.toml" {
    src = ../overlays/config.toml;
  } ''
    cp $src $out
    substituteInPlace $out \
      --subst-var-by glibcbin ${lib.getBin pkgs.glibc}
    # substituteInPlace $out \
    #   --subst-var-by nvidia-drivers ${lib.getBin unpatched-nvidia-driver}
    substituteInPlace $out \
      --subst-var-by container-cli-path "PATH=${lib.makeBinPath nvidia-pkgs}"
  '';
in
{

  virtualisation.docker = {
    enable = true;
    enableNvidia = true;
  };

  environment.systemPackages = with pkgs; [
    # https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/install-guide.html#id6
    # https://itnext.io/enabling-nvidia-gpus-on-k3s-for-cuda-workloads-a11b96f967b0
    nvidia-k3s
    cudaPackages.fabricmanager
    cudaPackages.cuda_nvml_dev
  ];

  environment.etc = {
    "nvidia-container-runtime/config.toml" = {
      source = runtime-config;
      mode = "0600";
    };
  };

  # This installs the nvidia driver
  # It seems that this service installs a mix of packages, both necessary and unnecessary.
  # The root nvidia-linux driver is here:
  # https://github.com/NixOS/nixpkgs/blob/nixos-22.11/pkgs/os-specific/linux/nvidia-x11/generic.nix#L125
  # We can test later if we can avoid installing X11 stuff along with the driver.
  services.xserver.videoDrivers = [ "nvidia" ];
  # This is required for some apps to see the driver
  hardware.opengl = {
    enable = true;
    driSupport32Bit = true;
    setLdLibraryPath = true;
  };

  # This selects the Nvidia Driver version, GTX 1070 is not yet legacy!
  hardware.nvidia.package = config.boot.kernelPackages.nvidiaPackages.stable;
  # Required to keep GPU awake for runtime
  hardware.nvidia.nvidiaPersistenced = true;

  # needed for ldconfig files
  # nvidia-container-cli was using the root /tmp/ld.conf.so anyways...
  # systemd.services.k3s.serviceConfig.PrivateTmp = true;

  # add nvidia pkgs to k3s PATH
  systemd.services.k3s.path = nvidia-pkgs;
  # add the libraries to PATH for the nvidia-driver-plugin to discover (which does a dynamic load)
  # https://github.com/NVIDIA/go-nvml/blob/6671dd5b56ed77ffd35b703c7694f63cfe01317f/pkg/dl/dl.go#L55
  # systemd.services.k3s.environment = {
  #   LD_LIBRARY_PATH =
  #     let inherit (pkgs.addOpenGLRunpath) driverLink;
  #     in
  #     lib.makeLibraryPath [ unpatched-nvidia-driver driverLink "${driverLink}-32" ];
  # };

  # FIXME: this resulted in a systemd unit stop crash loop
  ## here we can initialize the ld cache that nvidia requires
  # https://discourse.nixos.org/t/using-nvidia-container-runtime-with-containerd-on-nixos/27865/6
  systemd.services.k3s.preStart = ''
    rm -rf /tmp/nvidia-libs
    mkdir -p /tmp/nvidia-libs

    for LIB in {${unpatched-nvidia-driver}/lib/*,${pkgs.libtirpc}/lib/*,${pkgs.cudaPackages.cuda_nvml_dev}/lib/stubs/*}; do
      ln -s -f $(readlink -f $LIB) /tmp/nvidia-libs/$(basename $LIB)
    done

    echo "initializing nvidia ld cache"
    ldconfig -C /tmp/ld.so.cache /tmp/nvidia-libs

    echo "nvidia ld cache contents"
    ldconfig -C /tmp/ld.so.cache --print-cache
  '';
}
