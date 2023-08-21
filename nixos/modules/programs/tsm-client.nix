{ config, lib, pkgs, ... }:

let

  inherit (lib.attrsets) attrNames filterAttrs hasAttr mapAttrs mapAttrsToList optionalAttrs;
  inherit (lib.lists) allUnique map;
  inherit (lib.modules) mkDefault mkIf;
  inherit (lib.options) literalExpression mkEnableOption mkOption mkPackageOption;
  inherit (lib.strings) concatLines optionalString toLower;
  inherit (lib.types) addCheck attrsOf lines nonEmptyStr nullOr path port str strMatching submodule;

  # TSM rejects servername strings longer than 64 chars.
  servernameType = strMatching "[^[:space:]]{1,64}";

  serverOptions = { name, config, ... }: {
    options.name = mkOption {
      type = servernameType;
      example = "mainTsmServer";
      description = lib.mdDoc ''
        Local name of the IBM TSM server,
        must be uncapitalized and no longer than 64 chars.
        The value will be used for the
        `server`
        directive in {file}`dsm.sys`.
      '';
    };
    options.server = mkOption {
      type = nonEmptyStr;
      example = "tsmserver.company.com";
      description = lib.mdDoc ''
        Host/domain name or IP address of the IBM TSM server.
        The value will be used for the
        `tcpserveraddress`
        directive in {file}`dsm.sys`.
      '';
    };
    options.port = mkOption {
      type = addCheck port (p: p<=32767);
      default = 1500;  # official default
      description = lib.mdDoc ''
        TCP port of the IBM TSM server.
        The value will be used for the
        `tcpport`
        directive in {file}`dsm.sys`.
        TSM does not support ports above 32767.
      '';
    };
    options.node = mkOption {
      type = nonEmptyStr;
      example = "MY-TSM-NODE";
      description = lib.mdDoc ''
        Target node name on the IBM TSM server.
        The value will be used for the
        `nodename`
        directive in {file}`dsm.sys`.
      '';
    };
    options.genPasswd = mkEnableOption (lib.mdDoc ''
      automatic client password generation.
      This option influences the
      `passwordaccess`
      directive in {file}`dsm.sys`.
      The password will be stored in the directory
      given by the option {option}`passwdDir`.
      *Caution*:
      If this option is enabled and the server forces
      to renew the password (e.g. on first connection),
      a random password will be generated and stored
    '');
    options.passwdDir = mkOption {
      type = path;
      example = "/home/alice/tsm-password";
      description = lib.mdDoc ''
        Directory that holds the TSM
        node's password information.
        The value will be used for the
        `passworddir`
        directive in {file}`dsm.sys`.
      '';
    };
    options.includeExclude = mkOption {
      type = lines;
      default = "";
      example = ''
        exclude.dir     /nix/store
        include.encrypt /home/.../*
      '';
      description = lib.mdDoc ''
        `include.*` and
        `exclude.*` directives to be
        used when sending files to the IBM TSM server.
        The lines will be written into a file that the
        `inclexcl`
        directive in {file}`dsm.sys` points to.
      '';
    };
    options.extraConfig = mkOption {
      # TSM option keys are case insensitive;
      # we have to ensure there are no keys that
      # differ only by upper and lower case.
      type = addCheck
        (attrsOf (nullOr str))
        (attrs: allUnique (map toLower (attrNames attrs)));
      default = {};
      example.compression = "yes";
      example.passwordaccess = null;
      description = lib.mdDoc ''
        Additional key-value pairs for the server stanza.
        Values must be strings, or `null`
        for the key not to be used in the stanza
        (e.g. to overrule values generated by other options).
      '';
    };
    options.text = mkOption {
      type = lines;
      example = literalExpression
        ''lib.modules.mkAfter "compression no"'';
      description = lib.mdDoc ''
        Additional text lines for the server stanza.
        This option can be used if certion configuration keys
        must be used multiple times or ordered in a certain way
        as the {option}`extraConfig` option can't
        control the order of lines in the resulting stanza.
        Note that the `server`
        line at the beginning of the stanza is
        not part of this option's value.
      '';
    };
    options.stanza = mkOption {
      type = str;
      internal = true;
      visible = false;
      description = lib.mdDoc "Server stanza text generated from the options.";
    };
    config.name = mkDefault name;
    # Client system-options file directives are explained here:
    # https://www.ibm.com/docs/en/storage-protect/8.1.20?topic=commands-processing-options
    config.extraConfig =
      mapAttrs (lib.trivial.const mkDefault) (
        {
          commmethod = "v6tcpip";  # uses v4 or v6, based on dns lookup result
          tcpserveraddress = config.server;
          tcpport = builtins.toString config.port;
          nodename = config.node;
          passwordaccess = if config.genPasswd then "generate" else "prompt";
          passworddir = ''"${config.passwdDir}"'';
        } // optionalAttrs (config.includeExclude!="") {
          inclexcl = ''"${pkgs.writeText "inclexcl.dsm.sys" config.includeExclude}"'';
        }
      );
    config.text =
      let
        attrset = filterAttrs (k: v: v!=null) config.extraConfig;
        mkLine = k: v: k + optionalString (v!="") "  ${v}";
        lines = mapAttrsToList mkLine attrset;
      in
        concatLines lines;
    config.stanza = ''
      server  ${config.name}
      ${config.text}
    '';
  };

  options.programs.tsmClient = {
    enable = mkEnableOption (lib.mdDoc ''
      IBM Storage Protect (Tivoli Storage Manager, TSM)
      client command line applications with a
      client system-options file "dsm.sys"
    '');
    servers = mkOption {
      type = attrsOf (submodule serverOptions);
      default = {};
      example.mainTsmServer = {
        server = "tsmserver.company.com";
        node = "MY-TSM-NODE";
        extraConfig.compression = "yes";
      };
      description = lib.mdDoc ''
        Server definitions ("stanzas")
        for the client system-options file.
      '';
    };
    defaultServername = mkOption {
      type = nullOr servernameType;
      default = null;
      example = "mainTsmServer";
      description = lib.mdDoc ''
        If multiple server stanzas are declared with
        {option}`programs.tsmClient.servers`,
        this option may be used to name a default
        server stanza that IBM TSM uses in the absence of
        a user-defined {file}`dsm.opt` file.
        This option translates to a
        `defaultserver` configuration line.
      '';
    };
    dsmSysText = mkOption {
      type = lines;
      readOnly = true;
      description = lib.mdDoc ''
        This configuration key contains the effective text
        of the client system-options file "dsm.sys".
        It should not be changed, but may be
        used to feed the configuration into other
        TSM-depending packages used on the system.
      '';
    };
    package = mkPackageOption pkgs "tsm-client" {
      example = "tsm-client-withGui";
      extraDescription = ''
        It will be used with `.override`
        to add paths to the client system-options file.
      '';
    };
    wrappedPackage = mkPackageOption pkgs "tsm-client" {
      default = null;
      extraDescription = ''
        This option is to provide the effective derivation,
        wrapped with the path to the
        client system-options file "dsm.sys".
        It should not be changed, but exists
        for other modules that want to call TSM executables.
      '';
    } // { readOnly = true; };
  };

  cfg = config.programs.tsmClient;

  assertions = [
    {
      assertion = allUnique (mapAttrsToList (k: v: toLower v.name) cfg.servers);
      message = ''
        TSM servernames contain duplicate name
        (note that case doesn't matter!)
      '';
    }
    {
      assertion = (cfg.defaultServername!=null)->(hasAttr cfg.defaultServername cfg.servers);
      message = "TSM defaultServername not found in list of servers";
    }
  ];

  dsmSysText = ''
    ****  IBM Storage Protect (Tivoli Storage Manager)
    ****  client system-options file "dsm.sys".
    ****  Do not edit!
    ****  This file is generated by NixOS configuration.

    ${optionalString (cfg.defaultServername!=null) "defaultserver  ${cfg.defaultServername}"}

    ${concatLines (mapAttrsToList (k: v: v.stanza) cfg.servers)}
  '';

in

{

  inherit options;

  config = mkIf cfg.enable {
    inherit assertions;
    programs.tsmClient.dsmSysText = dsmSysText;
    programs.tsmClient.wrappedPackage = cfg.package.override rec {
      dsmSysCli = pkgs.writeText "dsm.sys" cfg.dsmSysText;
      dsmSysApi = dsmSysCli;
    };
    environment.systemPackages = [ cfg.wrappedPackage ];
  };

  meta.maintainers = [ lib.maintainers.yarny ];

}
