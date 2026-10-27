#!/usr/bin/env ruby
# Build-time only; uses Ruby's standard library. No XcodeGen or third-party gems.
require 'digest'
require 'fileutils'
require 'json'
Dir.chdir(File.expand_path('..', __dir__))
def id(key)
  Digest::SHA256.hexdigest(key)[0, 24].upcase
end
def q(value)
  value.to_s.to_json
end
objects = {}
add = ->(key, value) { objects[id(key)] = value; id(key) }
shared = Dir['Shared/**/*.swift'].sort
resources = ['Shared/Resources/Localizable.xcstrings', 'Shared/Resources/Assets.xcassets']
mac_icon = 'Shared/Resources/NetDockIcon.icon'
platforms = { 'Mac' => 'macosx', 'Mobile' => 'iphoneos' }
all_files = shared + resources + [mac_icon] + Dir['Apps/**/*.swift'] + Dir['Tests/NetDockUITests/*.swift']
refs = all_files.map do |path|
  type = path.end_with?('.swift') ? 'sourcecode.swift' : (path.end_with?('.xcstrings') ? 'text.json.xcstrings' : (path.end_with?('.icon') ? 'folder.iconcomposer' : 'folder.assetcatalog'))
  add.call(path, "isa = PBXFileReference; lastKnownFileType = #{type}; path = #{q(path)}; sourceTree = SOURCE_ROOT;")
end
# Localized permission prompts are bundled using variant groups.
permission_children = %w[en zh-Hans].map do |lang|
  path = "Shared/Resources/#{lang}.lproj/InfoPlist.strings"
  add.call(path, "isa = PBXFileReference; lastKnownFileType = text.plist.strings; name = #{q(lang)}; path = #{q(path)}; sourceTree = SOURCE_ROOT;")
end
permission = add.call('InfoPlist.strings', "isa = PBXVariantGroup; children = (#{permission_children.join(',')}); name = InfoPlist.strings; sourceTree = \"<group>\";")
refs << permission
pkg = add.call('package', 'isa = XCLocalSwiftPackageReference; relativePath = Packages/NetDockCore;')
products = []; targets = []; config_lists = {}
platforms.each do |suffix, sdk|
  name = "NetDock#{suffix}"
  product = add.call("product-#{suffix}", "isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = #{name}.app; sourceTree = BUILT_PRODUCTS_DIR;")
  products << product
  dep = add.call("dependency-#{suffix}", "isa = XCSwiftPackageProductDependency; package = #{pkg}; productName = NetDockCore;")
  framework = add.call("framework-#{suffix}", "isa = PBXBuildFile; productRef = #{dep};")
  source_files = shared + Dir["Apps/#{name}/*.swift"]
  source_ids = source_files.map { |p| add.call("build-#{suffix}-#{p}", "isa = PBXBuildFile; fileRef = #{id(p)};") }
  resource_ids = resources.map { |p| add.call("build-#{suffix}-#{p}", "isa = PBXBuildFile; fileRef = #{id(p)};") }
  resource_ids << add.call("build-#{suffix}-#{mac_icon}", "isa = PBXBuildFile; fileRef = #{id(mac_icon)};") if suffix == 'Mac'
  resource_ids << add.call("build-#{suffix}-permission", "isa = PBXBuildFile; fileRef = #{permission};")
  sources = add.call("sources-#{suffix}", "isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (#{source_ids.join(',')}); runOnlyForDeploymentPostprocessing = 0;")
  res = add.call("resources-#{suffix}", "isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = (#{resource_ids.join(',')}); runOnlyForDeploymentPostprocessing = 0;")
  fw = add.call("frameworks-#{suffix}", "isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (#{framework}); runOnlyForDeploymentPostprocessing = 0;")
  configs = %w[Debug Release].map do |config|
    settings = {
      'PRODUCT_NAME' => name, 'PRODUCT_BUNDLE_IDENTIFIER' => "org.netdock.#{suffix.downcase}",
      'SDKROOT' => sdk, 'SWIFT_VERSION' => '6.0', 'GENERATE_INFOPLIST_FILE' => 'YES',
      'ASSETCATALOG_COMPILER_APPICON_NAME' => suffix == 'Mac' ? 'NetDockIcon' : 'AppIcon',
      'MARKETING_VERSION' => '0.1.0', 'CURRENT_PROJECT_VERSION' => '1',
      'INFOPLIST_KEY_CFBundleDisplayName' => 'NetDock', 'SWIFT_STRICT_CONCURRENCY' => 'complete',
      'INFOPLIST_KEY_CFBundleName' => 'NetDock',
      'SWIFT_EMIT_LOC_STRINGS' => 'YES', 'LOCALIZATION_PREFERS_STRING_CATALOGS' => 'YES',
      'SWIFT_OPTIMIZATION_LEVEL' => config == 'Debug' ? '-Onone' : '-O',
      'ENABLE_HARDENED_RUNTIME' => 'YES'
    }
    settings['ONLY_ACTIVE_ARCH'] = 'YES' if config == 'Debug'
    settings['CODE_SIGN_INJECT_BASE_ENTITLEMENTS'] = 'NO' if config == 'Release'
    if suffix == 'Mac'
      settings.merge!('ARCHS' => 'arm64', 'MACOSX_DEPLOYMENT_TARGET' => '14.0', 'CODE_SIGN_ENTITLEMENTS' => 'Apps/NetDockMac/NetDockMac.entitlements',
        'CODE_SIGN_IDENTITY' => '-', 'CODE_SIGN_STYLE' => 'Manual', 'INFOPLIST_KEY_LSApplicationCategoryType' => 'public.app-category.developer-tools',
        'SUPPORTED_PLATFORMS' => 'macosx', 'LD_RUNPATH_SEARCH_PATHS' => '$(inherited) @executable_path/../Frameworks')
    else
      settings.merge!('IPHONEOS_DEPLOYMENT_TARGET' => '17.0', 'TARGETED_DEVICE_FAMILY' => '1,2',
        'SUPPORTED_PLATFORMS' => 'iphoneos iphonesimulator', 'SUPPORTS_MACCATALYST' => 'NO',
        'CODE_SIGN_STYLE' => 'Automatic', 'INFOPLIST_KEY_UILaunchScreen_Generation' => 'YES',
        'INFOPLIST_KEY_NSLocalNetworkUsageDescription' => 'NetDock 需要访问局域网，以便连接和调试您指定的 TCP/UDP 设备与服务。',
        'INFOPLIST_KEY_UISupportedInterfaceOrientations' => 'UIInterfaceOrientationPortrait UIInterfaceOrientationPortraitUpsideDown UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight',
        'LD_RUNPATH_SEARCH_PATHS' => '$(inherited) @executable_path/Frameworks')
    end
    add.call("config-#{suffix}-#{config}", "isa = XCBuildConfiguration; buildSettings = {#{settings.map { |k,v| "#{q(k)} = #{q(v)};" }.join}}; name = #{config};")
  end
  config_list = add.call("configs-#{suffix}", "isa = XCConfigurationList; buildConfigurations = (#{configs.join(',')}); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;")
  target = add.call("target-#{suffix}", "isa = PBXNativeTarget; buildConfigurationList = #{config_list}; buildPhases = (#{sources},#{fw},#{res}); buildRules = (); dependencies = (); name = #{name}; packageProductDependencies = (#{dep}); productName = #{name}; productReference = #{product}; productType = \"com.apple.product-type.application\";")
  targets << target
  test_name = "#{name}UITests"
  test_product = add.call("test-product-#{suffix}", "isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = #{test_name}.xctest; sourceTree = BUILT_PRODUCTS_DIR;")
  products << test_product
  test_files = Dir['Tests/NetDockUITests/*.swift'].sort.map { |p| add.call("test-build-#{suffix}-#{p}", "isa = PBXBuildFile; fileRef = #{id(p)};") }
  test_sources = add.call("test-sources-#{suffix}", "isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (#{test_files.join(',')}); runOnlyForDeploymentPostprocessing = 0;")
  test_configs = %w[Debug Release].map do |config|
    settings = {
      'PRODUCT_NAME' => test_name, 'PRODUCT_BUNDLE_IDENTIFIER' => "org.netdock.#{suffix.downcase}.uitests",
      'SDKROOT' => sdk, 'SWIFT_VERSION' => '6.0', 'GENERATE_INFOPLIST_FILE' => 'YES', 'TEST_TARGET_NAME' => name,
      'ONLY_ACTIVE_ARCH' => 'YES', 'CODE_SIGN_STYLE' => suffix == 'Mac' ? 'Manual' : 'Automatic'
    }
    if suffix == 'Mac'
      settings.merge!('ARCHS'=>'arm64', 'MACOSX_DEPLOYMENT_TARGET'=>'14.0', 'CODE_SIGN_IDENTITY'=>'-', 'SUPPORTED_PLATFORMS'=>'macosx', 'CODE_SIGN_ENTITLEMENTS'=>'Tests/NetDockUITests/Runner.entitlements')
    else
      settings.merge!('IPHONEOS_DEPLOYMENT_TARGET'=>'17.0', 'TARGETED_DEVICE_FAMILY'=>'1,2', 'SUPPORTED_PLATFORMS'=>'iphoneos iphonesimulator')
    end
    add.call("test-config-#{suffix}-#{config}", "isa = XCBuildConfiguration; buildSettings = {#{settings.map { |k,v| "#{q(k)} = #{q(v)};" }.join}}; name = #{config};")
  end
  test_config_list = add.call("test-configs-#{suffix}", "isa = XCConfigurationList; buildConfigurations = (#{test_configs.join(',')}); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;")
  proxy = add.call("test-proxy-#{suffix}", "isa = PBXContainerItemProxy; containerPortal = #{id('project')}; proxyType = 1; remoteGlobalIDString = #{target}; remoteInfo = #{name};")
  dependency = add.call("test-target-dependency-#{suffix}", "isa = PBXTargetDependency; target = #{target}; targetProxy = #{proxy};")
  test_target = add.call("test-target-#{suffix}", "isa = PBXNativeTarget; buildConfigurationList = #{test_config_list}; buildPhases = (#{test_sources}); buildRules = (); dependencies = (#{dependency}); name = #{test_name}; productName = #{test_name}; productReference = #{test_product}; productType = \"com.apple.product-type.bundle.ui-testing\";")
  targets << test_target
  FileUtils.mkdir_p('NetDock.xcodeproj/xcshareddata/xcschemes')
  File.write("NetDock.xcodeproj/xcshareddata/xcschemes/#{name}.xcscheme", <<~XML)
    <?xml version="1.0" encoding="UTF-8"?>
    <Scheme LastUpgradeVersion="2700" version="1.3">
      <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="#{target}" BuildableName="#{name}.app" BlueprintName="#{name}" ReferencedContainer="container:NetDock.xcodeproj"/></BuildActionEntry></BuildActionEntries></BuildAction>
      <TestAction buildConfiguration="Debug" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="#{test_target}" BuildableName="#{test_name}.xctest" BlueprintName="#{test_name}" ReferencedContainer="container:NetDock.xcodeproj"/></TestableReference></Testables></TestAction>
      <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="#{target}" BuildableName="#{name}.app" BlueprintName="#{name}" ReferencedContainer="container:NetDock.xcodeproj"/></BuildableProductRunnable></LaunchAction>
      <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"/>
      <AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
    </Scheme>
  XML
end
products_group = add.call('products', "isa = PBXGroup; children = (#{products.join(',')}); name = Products; sourceTree = \"<group>\";")
main_group = add.call('main', "isa = PBXGroup; children = (#{(refs + [products_group]).join(',')}); sourceTree = \"<group>\";")
project_configs = %w[Debug Release].map do |config|
  add.call("project-#{config}", "isa = XCBuildConfiguration; buildSettings = {CLANG_ENABLE_MODULES = YES; ENABLE_USER_SCRIPT_SANDBOXING = YES; DEBUG_INFORMATION_FORMAT = #{config == 'Debug' ? 'dwarf' : '"dwarf-with-dsym"'}; }; name = #{config};")
end
project_config_list = add.call('project-configs', "isa = XCConfigurationList; buildConfigurations = (#{project_configs.join(',')}); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;")
project = add.call('project', "isa = PBXProject; attributes = {BuildIndependentTargetsInParallel = YES; LastUpgradeCheck = 2700; }; buildConfigurationList = #{project_config_list}; compatibilityVersion = \"Xcode 14.0\"; developmentRegion = \"zh-Hans\"; hasScannedForEncodings = 0; knownRegions = (en, \"zh-Hans\", Base); mainGroup = #{main_group}; packageReferences = (#{pkg}); productRefGroup = #{products_group}; projectDirPath = \"\"; projectRoot = \"\"; targets = (#{targets.join(',')});")
File.write('NetDock.xcodeproj/project.pbxproj', "// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 60; objects = {\n#{objects.map { |k,v| "#{k} = { #{v} };" }.join("\n")}\n}; rootObject = #{project}; }\n")
