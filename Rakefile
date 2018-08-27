require 'rake/clean'

LUAC = "luac"
ZIP = "zip"

BUILD_DIR = "build"
PLUGIN_DIR = File.join(BUILD_DIR, "robotagger.lrplugin")
DIST_DIR = "dist"

SOURCE_FILES = FileList[ File.join("src", "*.lua") ]
RESOURCE_FILES = FileList[ File.join("src", "*.png") ]
README_FILES = FileList[ "README.md", "LICENSE" ]
TARGET_FILES = SOURCE_FILES.pathmap(File.join(PLUGIN_DIR, "%f")) + README_FILES.pathmap(File.join(PLUGIN_DIR, "%f"))
PACKAGE_FILE = File.join(DIST_DIR, "robotagger.zip")

task :default => [ :compile, :package ]

directory BUILD_DIR
CLEAN << BUILD_DIR

directory PLUGIN_DIR
CLEAN << PLUGIN_DIR

directory DIST_DIR
CLOBBER << DIST_DIR

desc "Compile source files"
task :compile => [ :test, PLUGIN_DIR ]

task :test do
  sh "#{LUAC} -v | grep 5.1"
end

SOURCE_FILES.each do |src|
	tgt = src.pathmap(File.join(PLUGIN_DIR, "%f"))
	file tgt => src do
		sh "#{LUAC} -o #{tgt} #{src}"
	end
	CLEAN << tgt
	task :compile => tgt
	task PACKAGE_FILE => tgt
end

(RESOURCE_FILES + README_FILES).each do |src|
	tgt = src.pathmap(File.join(PLUGIN_DIR, "%f"))
	file tgt => src do
		cp src, tgt
	end
	CLEAN << tgt
	task PACKAGE_FILE => tgt
end

desc "Create distribution package file"
task :package => [ :compile, PACKAGE_FILE ]

task PACKAGE_FILE => DIST_DIR do
	sh "cd #{BUILD_DIR} && #{ZIP} --recurse-paths #{File.absolute_path(PACKAGE_FILE)} #{PLUGIN_DIR.pathmap("%f")}"
end
