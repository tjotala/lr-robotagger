--[[----------------------------------------------------------------------------

 Automatically Tag Photos using Google Vision API
 Copyright 2017-2024 Tapani Otala
 Updated for Lightroom Classic 2024

--------------------------------------------------------------------------------

Info.lua
Summary information for the plug-in.

Adds menu items to Lightroom.

------------------------------------------------------------------------------]]

return {

	LrSdkVersion = 13.0,
	LrSdkMinimumVersion = 10.0, -- minimum SDK version required by this plug-in

	LrToolkitIdentifier = "com.tjotala.lightroom.robotagger",

	LrPluginName = LOC( "$$$/RoboTagger/PluginName=RoboTagger" ),
	LrPluginInfoUrl = "https://github.com/obelix74/lr-robotagger",
	LrPluginInfoProvider = "RoboTaggerInfoProvider.lua",

	LrInitPlugin = "RoboTaggerInit.lua",
	LrShutdownPlugin = "RoboTaggerShutdown.lua",

	-- Add the menu item to the File menu.

	LrExportMenuItems = {
		{
			title = LOC( "$$$/RoboTagger/LibraryMenuItem=Tag Photos with Google Vision" ),
			file = "RoboTaggerMenuItem.lua",
			enabledWhen = "photosSelected",
		},
	},

	-- Add the menu item to the Library menu.

	LrLibraryMenuItems = {
		{
			title = LOC( "$$$/RoboTagger/LibraryMenuItem=Tag Photos with Google Vision" ),
			file = "RoboTaggerMenuItem.lua",
			enabledWhen = "photosSelected",
		},
	},

	VERSION = { major = 2, minor = 0, revision = 0, build = 1, },

}
