#!/usr/bin/env ruby
# frozen_string_literal: true

require 'fileutils'
require 'xcodeproj'

PROJECT_NAME = 'ticket-crushers'
PROJECT_PATH = "#{PROJECT_NAME}.xcodeproj"
DEPLOYMENT_TARGET = '13.0'

FileUtils.rm_rf(PROJECT_PATH)
project = Xcodeproj::Project.new(PROJECT_PATH)

project.root_object.attributes['LastSwiftUpdateCheck'] = '1600'
project.root_object.attributes['LastUpgradeCheck'] = '1600'

main_group = project.main_group
sources_group = main_group.find_subpath('Sources', true)
frameworks_group = project.frameworks_group || main_group.new_group('Frameworks')

module_groups = {
  'TicketCrusherCore' => sources_group.find_subpath('TicketCrusherCore', true),
  'TicketCrusherStorage' => sources_group.find_subpath('TicketCrusherStorage', true),
  'TicketCrusherFeatures' => sources_group.find_subpath('TicketCrusherFeatures', true),
  'TicketCrusherIntegrations' => sources_group.find_subpath('TicketCrusherIntegrations', true),
  'TicketCrusherApp' => sources_group.find_subpath('TicketCrusherApp', true),
  'TicketCrusherChecks' => sources_group.find_subpath('TicketCrusherChecks', true)
}

def configure_build_settings(target, bundle_id: nil, is_framework: false, is_app: false, is_tool: false)
  target.build_configurations.each do |config|
    settings = config.build_settings
    settings['SWIFT_VERSION'] = '5.9'
    settings['MACOSX_DEPLOYMENT_TARGET'] = DEPLOYMENT_TARGET
    settings['CLANG_ENABLE_MODULES'] = 'YES'
    settings['CODE_SIGN_STYLE'] = 'Automatic'
    settings['DEVELOPMENT_TEAM'] = ''
    settings['CURRENT_PROJECT_VERSION'] = '1'
    settings['MARKETING_VERSION'] = '1.0'
    settings['GENERATE_INFOPLIST_FILE'] = 'YES'
    settings['PRODUCT_BUNDLE_IDENTIFIER'] = bundle_id if bundle_id

    if is_framework
      settings['DEFINES_MODULE'] = 'YES'
      settings['SKIP_INSTALL'] = 'YES'
      settings['INSTALL_PATH'] = '$(LOCAL_LIBRARY_DIR)/Frameworks'
      settings['LD_RUNPATH_SEARCH_PATHS'] = ['$(inherited)', '@loader_path/Frameworks', '@loader_path/../Frameworks']
      settings['DYLIB_INSTALL_NAME_BASE'] = '@rpath'
      settings['VERSIONING_SYSTEM'] = 'apple-generic'
    end

    if is_app
      settings['LD_RUNPATH_SEARCH_PATHS'] = ['$(inherited)', '@executable_path/../Frameworks']
      settings['ENABLE_HARDENED_RUNTIME'] = 'YES'
      settings['PRODUCT_NAME'] = 'TicketCrusherApp'
    end

    if is_tool
      settings['PRODUCT_NAME'] = target.name
      settings['LD_RUNPATH_SEARCH_PATHS'] = ['$(inherited)', '@executable_path', '@loader_path', '@executable_path/../Frameworks']
    end
  end
end

def add_swift_sources(target, group, directory)
  Dir.glob(File.join(directory, '*.swift')).sort.each do |source_file|
    file_ref = group.new_file(source_file)
    target.add_file_references([file_ref])
  end
end

def add_resource_files(target, group, directory)
  return unless Dir.exist?(directory)

  resources_group = group.find_subpath('Resources', true)
  Dir.glob(File.join(directory, '**', '*')).sort.each do |resource_file|
    next if File.directory?(resource_file)

    file_ref = resources_group.new_file(resource_file)
    target.resources_build_phase.add_file_reference(file_ref, true)
  end
end

def add_target_dependency_with_link(target, dependency_target)
  target.add_dependency(dependency_target)
  target.frameworks_build_phase.add_file_reference(dependency_target.product_reference, true)
end

core_target = project.new_target(:framework, 'TicketCrusherCore', :osx, DEPLOYMENT_TARGET, nil, :swift)
storage_target = project.new_target(:framework, 'TicketCrusherStorage', :osx, DEPLOYMENT_TARGET, nil, :swift)
features_target = project.new_target(:framework, 'TicketCrusherFeatures', :osx, DEPLOYMENT_TARGET, nil, :swift)
integrations_target = project.new_target(:framework, 'TicketCrusherIntegrations', :osx, DEPLOYMENT_TARGET, nil, :swift)
checks_target = project.new_target(:command_line_tool, 'TicketCrusherChecks', :osx, DEPLOYMENT_TARGET, nil, :swift)
app_target = project.new_target(:application, 'TicketCrusherApp', :osx, DEPLOYMENT_TARGET, nil, :swift)

configure_build_settings(core_target, bundle_id: 'com.jimdaley.ticketcrusher.core', is_framework: true)
configure_build_settings(storage_target, bundle_id: 'com.jimdaley.ticketcrusher.storage', is_framework: true)
configure_build_settings(features_target, bundle_id: 'com.jimdaley.ticketcrusher.features', is_framework: true)
configure_build_settings(integrations_target, bundle_id: 'com.jimdaley.ticketcrusher.integrations', is_framework: true)
configure_build_settings(checks_target, bundle_id: 'com.jimdaley.ticketcrusher.checks', is_tool: true)
configure_build_settings(app_target, bundle_id: 'com.jimdaley.ticketcrusher', is_app: true)

add_swift_sources(core_target, module_groups['TicketCrusherCore'], 'Sources/TicketCrusherCore')
add_swift_sources(storage_target, module_groups['TicketCrusherStorage'], 'Sources/TicketCrusherStorage')
add_swift_sources(features_target, module_groups['TicketCrusherFeatures'], 'Sources/TicketCrusherFeatures')
add_swift_sources(integrations_target, module_groups['TicketCrusherIntegrations'], 'Sources/TicketCrusherIntegrations')
add_swift_sources(checks_target, module_groups['TicketCrusherChecks'], 'Sources/TicketCrusherChecks')
add_swift_sources(app_target, module_groups['TicketCrusherApp'], 'Sources/TicketCrusherApp')
add_resource_files(app_target, module_groups['TicketCrusherApp'], 'Sources/TicketCrusherApp/Resources')

add_target_dependency_with_link(storage_target, core_target)
add_target_dependency_with_link(features_target, core_target)
add_target_dependency_with_link(integrations_target, core_target)

add_target_dependency_with_link(checks_target, core_target)
add_target_dependency_with_link(checks_target, storage_target)
add_target_dependency_with_link(checks_target, features_target)

add_target_dependency_with_link(app_target, core_target)
add_target_dependency_with_link(app_target, storage_target)
add_target_dependency_with_link(app_target, features_target)
add_target_dependency_with_link(app_target, integrations_target)

sqlite_ref = frameworks_group.new_file('usr/lib/libsqlite3.tbd')
sqlite_ref.source_tree = 'SDKROOT'
storage_target.frameworks_build_phase.add_file_reference(sqlite_ref, true)

embed_frameworks = app_target.new_copy_files_build_phase('Embed Frameworks')
embed_frameworks.dst_subfolder_spec = '10'
[core_target, storage_target, features_target, integrations_target].each do |framework_target|
  build_file = embed_frameworks.add_file_reference(framework_target.product_reference, true)
  build_file.settings = { 'ATTRIBUTES' => ['CodeSignOnCopy', 'RemoveHeadersOnCopy'] }
end

scheme_app = Xcodeproj::XCScheme.new
scheme_app.set_launch_target(app_target)
scheme_app.save_as(PROJECT_PATH, 'TicketCrusherApp', true)

scheme_checks = Xcodeproj::XCScheme.new
scheme_checks.set_launch_target(checks_target)
scheme_checks.save_as(PROJECT_PATH, 'TicketCrusherChecks', true)

project.save
puts "Generated #{PROJECT_PATH}"
