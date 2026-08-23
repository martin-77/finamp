#!/usr/bin/env ruby
# frozen_string_literal: true

require "xcodeproj"
require "xcodeproj/plist"

project_path = File.expand_path("../ios/Runner.xcodeproj", __dir__)
runner_entitlements_path = File.expand_path("../ios/Runner/Runner.entitlements", __dir__)
project = Xcodeproj::Project.open(project_path)

runner = project.targets.find { |target| target.name == "Runner" }
abort("Runner target not found") unless runner

widget_name = "FinampWidgetExtension"
widget = project.targets.find { |target| target.name == widget_name } ||
         project.new_target(:app_extension, widget_name, :ios, "17.0")

widget_group = project.main_group.find_subpath("FinampWidget", true)
widget_group.set_source_tree("<group>")
widget_group.path = "FinampWidget"

source_names = %w[
  WidgetState.swift
  WidgetIntents.swift
  FinampWidget.swift
  FinampWidgetBundle.swift
]

refs = source_names.to_h do |name|
  ref = widget_group.files.find { |file| file.path == name } || widget_group.new_file(name)
  [name, ref]
end

source_names.each do |name|
  ref = refs.fetch(name)
  widget.source_build_phase.add_file_reference(ref, true)
end

runner_group = project.main_group.find_subpath("Runner", false)
abort("Runner group not found") unless runner_group

bridge_ref = runner_group.files.find { |file| file.path == "WidgetBridge.swift" } ||
             runner_group.new_file("WidgetBridge.swift")
runner.source_build_phase.add_file_reference(bridge_ref, true)

%w[WidgetState.swift WidgetIntents.swift].each do |name|
  runner.source_build_phase.add_file_reference(refs.fetch(name), true)
end

runner_bundle_ids = runner.build_configurations.to_h do |config|
  [config.name, config.build_settings["PRODUCT_BUNDLE_IDENTIFIER"]]
end

widget.build_configurations.each do |config|
  main_bundle_id = runner_bundle_ids[config.name] || runner_bundle_ids.values.compact.first
  abort("Runner PRODUCT_BUNDLE_IDENTIFIER missing for #{config.name}") if main_bundle_id.nil?

  app_group = "group.#{main_bundle_id}.widget"

  config.build_settings["PRODUCT_NAME"] = "FinampWidgetExtension"
  config.build_settings["PRODUCT_BUNDLE_IDENTIFIER"] = "#{main_bundle_id}.FinampWidget"
  config.build_settings["INFOPLIST_FILE"] = "FinampWidget/Info.plist"
  config.build_settings["GENERATE_INFOPLIST_FILE"] = "YES"
  config.build_settings["CODE_SIGN_ENTITLEMENTS"] = "FinampWidget/FinampWidget.entitlements"
  config.build_settings["IPHONEOS_DEPLOYMENT_TARGET"] = "17.0"
  config.build_settings["SWIFT_VERSION"] = "5.0"
  config.build_settings["FINAMP_WIDGET_APP_GROUP"] = app_group
  config.build_settings["SKIP_INSTALL"] = "YES"
  config.build_settings["APPLICATION_EXTENSION_API_ONLY"] = "YES"
  config.build_settings["MARKETING_VERSION"] ||= "1.0"
  config.build_settings["CURRENT_PROJECT_VERSION"] ||= "1"
end

runner.build_configurations.each do |config|
  bundle_id = config.build_settings["PRODUCT_BUNDLE_IDENTIFIER"]
  next if bundle_id.nil?
  config.build_settings["FINAMP_WIDGET_APP_GROUP"] = "group.#{bundle_id}.widget"
end

entitlements = if File.exist?(runner_entitlements_path)
                 Xcodeproj::Plist.read_from_path(runner_entitlements_path)
               else
                 {}
               end
groups = Array(entitlements["com.apple.security.application-groups"])
groups << "$(FINAMP_WIDGET_APP_GROUP)" unless groups.include?("$(FINAMP_WIDGET_APP_GROUP)")
entitlements["com.apple.security.application-groups"] = groups
Xcodeproj::Plist.write_to_path(entitlements, runner_entitlements_path)

embed_phase = runner.copy_files_build_phases.find { |phase| phase.name == "Embed App Extensions" }
unless embed_phase
  embed_phase = runner.new_copy_files_build_phase("Embed App Extensions")
  embed_phase.dst_subfolder_spec = "13"
end

# Flutter requires embedded app extensions to be processed before its
# Run Script phase. Leaving a newly-created copy phase at the end of the
# Runner build phases can create a dependency cycle with Thin Binary and
# CocoaPods embed phases.
runner.build_phases.delete(embed_phase)

flutter_run_script_index = runner.build_phases.index do |phase|
  phase.respond_to?(:name) && phase.name == "Run Script"
end

if flutter_run_script_index
  runner.build_phases.insert(flutter_run_script_index, embed_phase)
else
  runner.build_phases << embed_phase
end

product_ref = widget.product_reference
unless embed_phase.files_references.include?(product_ref)
  build_file = embed_phase.add_file_reference(product_ref)
  build_file.settings = { "ATTRIBUTES" => ["RemoveHeadersOnCopy"] }
end

runner.add_dependency(widget) unless runner.dependencies.any? { |dependency| dependency.target == widget }

project.save
puts "Configured #{widget_name}, App Group entitlement, and Runner embedding."
