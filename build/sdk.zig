const std = @import("std");

pub fn addProxyBridgeModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    dvui_dep: *std.Build.Dependency,
    dvui_module: *std.Build.Module,
) *std.Build.Module {
    const mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = dvui_dep.path("src/backends/proxy_bridge.zig"),
    });
    mod.addImport("dvui", dvui_module);
    return mod;
}

pub fn wireSdkModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    dvui_module: *std.Build.Module,
    proxy_bridge_module: *std.Build.Module,
    core_module: *std.Build.Module,
    consumer: ?*std.Build.Module,
) *std.Build.Module {
    const sdk_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/sdk/sdk.zig"),
    });
    sdk_module.addImport("dvui", dvui_module);
    sdk_module.addImport("proxy_bridge", proxy_bridge_module);
    sdk_module.addImport("core", core_module);
    // `sdk_version` as a *named* module rather than a relative `@import`: `sdk/sdk_version.zig`
    // is the single edit site for the triplet, but it sits outside this module's root
    // (`src/sdk/`), and Zig confines a module's relative imports to its own root — a named
    // module is the only way in. Wired identically on the third-party path in
    // `sdk/plugin_sdk.zig`'s `exportModules`; both must stay in step or `version.zig` fails to
    // compile (loudly, at the first build).
    sdk_module.addImport("sdk_version", b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("sdk/sdk_version.zig"),
    }));
    if (consumer) |c| c.addImport("fizzy_sdk", sdk_module);
    return sdk_module;
}
