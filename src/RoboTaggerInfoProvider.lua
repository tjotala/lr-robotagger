--[[----------------------------------------------------------------------------

 RoboTagger
 Copyright 2017 Tapani Otala

--------------------------------------------------------------------------------

RoboTaggerInfoProvider.lua

------------------------------------------------------------------------------]]

local LrApplication = import "LrApplication"
local LrPrefs = import "LrPrefs"
local LrTasks = import "LrTasks"
local LrHttp = import "LrHttp"
local LrStringUtils = import "LrStringUtils"
local LrPathUtils = import "LrPathUtils"
local LrDialogs = import "LrDialogs"
local LrBinding = import "LrBinding"
local LrColor = import "LrColor"
local LrView = import "LrView"
local bind = LrView.bind
local share = LrView.share

--------------------------------------------------------------------------------

local inspect = require "inspect"
require "Logger"
require "GoogleVisionAPI"

--------------------------------------------------------------------------------

local prefs = LrPrefs.prefsForPlugin()

-- shared properties for aligning prompts
local propGeneralOptionsPromptWidth = "generalOptionsPromptWidth"
local propLabelOptionsPromptWidth = "labelOptionsPromptWidth"
local propLandmarkOptionsPromptWidth = "landmarkOptionsPromptWidth"
local propCredentialsPromptWidth = "credentialsPromptWidth"

-- properties for option controls
local propGeneralMaxTasks = "generalMaxTasks"

local propLabelThreshold = "labelThreshold"
local propDecorateLabelKeyword = "decorateLabelKeyword"
local propDecorateLabelValue = "decorateLabelValue"

local propLandmarkThreshold = "landmarkThreshold"
local propDecorateLandmarkKeyword = "decorateLandmarkKeyword"
local propDecorateLandmarkValue = "decorateLandmarkValue"
local propLandmarkCopyLocation = "landmarkCopyLocation"

local propClientEmail = "clientEmail"
local propServiceKey = "serviceKey"
local propVersions = "versions"

-- canned strings
local loadingText = LOC( "$$$/RoboTagger/Options/Loading=loading..." )
local sampleKeyword = LOC( "$$$/RoboTagger/Options/DecorateKeywords/SampleKeyword=sample keyword" )

local titleKeywordAsIs   = LOC( "$$$/RoboTagger/Options/DecorateKeywords/Title/None=as-is" )
local titleKeywordPrefix = LOC( "$$$/RoboTagger/Options/DecorateKeywords/Title/Prefix=with Prefix" )
local titleKeywordSuffix = LOC( "$$$/RoboTagger/Options/DecorateKeywords/Title/Suffix=with Suffix" )
local titleKeywordParent = LOC( "$$$/RoboTagger/Options/DecorateKeywords/Title/Parent=under Parent" )

local placeholderKeywordPrefix = LOC( "$$$/RoboTagger/Options/DecorateKeywords/PlaceHolder/Prefix=<prefix>" )
local placeholderKeywordSuffix = LOC( "$$$/RoboTagger/Options/DecorateKeywords/PlaceHolder/Suffix=<suffix>" )
local placeholderKeywordParent = LOC( "$$$/RoboTagger/Options/DecorateKeywords/PlaceHolder/Parent=<parent>" )

--------------------------------------------------------------------------------

local function renderSampleKeyword( decoration, value )
	if value then
		value = LrStringUtils.trimWhitespace( value )
		if value == "" then
			value = nil
		end
	end
	if decoration == decorateKeywordPrefix then
		return string.format( "%s %s", value or placeholderKeywordPrefix, sampleKeyword )
	elseif decoration == decorateKeywordSuffix then
		return string.format( "%s %s", sampleKeyword, value or placeholderKeywordSuffix )
	elseif decoration == decorateKeywordParent then
		return string.format( "%s/%s", value or placeholderKeywordParent, sampleKeyword )
	end
	-- decoration == decorateKeywordAsIs
	return sampleKeyword
end

local function loadCredentials( propertyTable, fileName )
	local creds = nil
	
	if fileName then
		logger:tracef( "loading credentials from %s", inspect( fileName ) )
		creds = GoogleVisionAPI.loadCredentialsFromFile( fileName )
	else
		logger:tracef( "loading credentials from keystore" )
		creds = GoogleVisionAPI.getCredentials()
	end
	if creds then
		propertyTable[ propClientEmail ] = creds.client_email
		propertyTable[ propServiceKey ] = creds.private_key
	else
		propertyTable[ propClientEmail ] = nil
		propertyTable[ propServiceKey ] = nil
	end
end

local function storeCredentials( propertyTable )
	GoogleVisionAPI.storeCredentials( {
		client_email = propertyTable[ propClientEmail ],
		private_key = propertyTable[ propServiceKey ],
	} )
end

local function clearCredentials( propertyTable )
	GoogleVisionAPI.clearCredentials()
	loadCredentials( propertyTable, nil )
end

local function startDialog( propertyTable )
	logger:tracef( "RoboTaggerInfoProvider: startDialog" )

	propertyTable[ propVersions ] = {
		vision = {
			version = loadingText,
		},
		openssl = {
			version = loadingText,
		},
	}
	LrTasks.startAsyncTask(
		function()
			logger:tracef( "getting Google Vision API versions" )
			propertyTable[ propVersions ] = GoogleVisionAPI.getVersions()
			logger:tracef( "got Google Vision API versions" )
		end
	)

	propertyTable[ propGeneralMaxTasks ] = prefs.maxTasks

	propertyTable[ propLabelThreshold ] = prefs.labelThreshold
	propertyTable[ propDecorateLabelKeyword ] = prefs.decorateLabelKeyword
	propertyTable[ propDecorateLabelValue ] = prefs.decorateLabelValue

	propertyTable[ propLandmarkThreshold ] = prefs.landmarkThreshold
	propertyTable[ propDecorateLandmarkKeyword ] = prefs.decorateLandmarkKeyword
	propertyTable[ propDecorateLandmarkValue ] = prefs.decorateLandmarkValue
	propertyTable[ propLandmarkCopyLocation ] = prefs.landmarkCopyLocation

	loadCredentials( propertyTable, nil )
end

local function endDialog( propertyTable )
	logger:tracef( "RoboTaggerInfoProvider: endDialog" )

	prefs.maxTasks = propertyTable[ propGeneralMaxTasks ]

	prefs.labelThreshold = propertyTable[ propLabelThreshold ]
	prefs.decorateLabelKeyword = propertyTable[ propDecorateLabelKeyword ]
	prefs.decorateLabelValue = LrStringUtils.trimWhitespace( propertyTable[ propDecorateLabelValue ] or "" )

	prefs.landmarkThreshold = propertyTable[ propLandmarkThreshold ]
	prefs.decorateLandmarkKeyword = propertyTable[ propDecorateLandmarkKeyword ]
	prefs.decorateLandmarkValue = LrStringUtils.trimWhitespace( propertyTable[ propDecorateLandmarkValue ] or "" )
	prefs.landmarkCopyLocation = propertyTable[ propLandmarkCopyLocation ]

	storeCredentials( propertyTable )
end

local function sectionsForTopOfDialog( f, propertyTable )
	logger:tracef( "RoboTaggerInfoProvider: sectionsForTopOfDialog" )

	return {
		-- general options
		{
			bind_to_object = propertyTable,
			title = LOC( "$$$/RoboTagger/Options/General/Title=General Options" ),
			spacing = f:control_spacing(),
			f:row {
				fill_horizontal = 1,
				f:static_text {
					title = LOC( "$$$/RoboTagger/Options/General/MaxTasks=Max Parallel Requests:" ),
					width = share( propGeneralOptionsPromptWidth ),
					alignment = "right",
				},
				f:edit_field {
					placeholder_string = LOC( "$$$/RoboTagger/Options/General/MaxTasks=<max requests>" ),
					value = bind { key = propGeneralMaxTasks },
					immediate = true,
					min = tasksMin,
					max = tasksMax,
					increment = tasksStep,
					precision = 0,
					width_in_digits = 4,
				},
				f:static_text {
					title = string.format( "%d", tasksMin ),
					alignment = "right",
				},
				f:slider {
					fill_horizontal = 1,
					value = bind { key = propGeneralMaxTasks },
					min = tasksMin,
					max = tasksMax,
					integral = tasksStep,
				},
				f:static_text {
					title = string.format( "%d", tasksMax ),
					alignment = "left",
				},
			},
		},
		-- label options
		{
			bind_to_object = propertyTable,
			title = LOC( "$$$/RoboTagger/Options/Labels/Title=Label Options" ),
			spacing = f:control_spacing(),
			f:row {
				fill_horizontal = 1,
				f:static_text {
					title = LOC( "$$$/RoboTagger/Options/Labels/Threshold=Score Threshold:" ),
					width = share( propLabelOptionsPromptWidth ),
					alignment = "right",
				},
				f:edit_field {
					placeholder_string = LOC( "$$$/RoboTagger/Options/Labels/ThresholdPlaceHolder=<threshold>" ),
					value = bind { key = propLabelThreshold },
					immediate = true,
					min = thresholdMin,
					max = thresholdMax,
					increment = thresholdStep,
					precision = 0,
					width_in_digits = 4,
				},
				f:static_text {
					title = string.format( "%d%%", thresholdMin ),
					alignment = "right",
				},
				f:slider {
					fill_horizontal = 1,
					value = bind { key = propLabelThreshold },
					min = thresholdMin,
					max = thresholdMax,
					integral = thresholdStep,
				},
				f:static_text {
					title = string.format( "%d%%", thresholdMax ),
					alignment = "left",
				},
			},
			f:row {
				fill_horizontal = 1,
				f:static_text {
					title = LOC( "$$$/RoboTagger/Options/Labels/Keywords/Prompt=Create Keywords:" ),
					width = share( propLabelOptionsPromptWidth ),
					alignment = "right",
				},
				f:popup_menu {
					value = bind { key = propDecorateLabelKeyword },
					items = {
						{ title = titleKeywordAsIs,   value = decorateKeywordAsIs   },
						{ title = titleKeywordPrefix, value = decorateKeywordPrefix },
						{ title = titleKeywordSuffix, value = decorateKeywordSuffix },
						{ title = titleKeywordParent, value = decorateKeywordParent },
					},
				},
				f:row {
					place = "overlapping",
					fill_horizontal = 0.5,
					f:edit_field {
						visible = LrBinding.keyEquals( propDecorateLabelKeyword, decorateKeywordPrefix ),
						placeholder_string = placeholderKeywordPrefix,
						value = bind { key = propDecorateLabelValue },
						immediate = true,
						width_in_chars = 10,
					},
					f:edit_field {
						visible = LrBinding.keyEquals( propDecorateLabelKeyword, decorateKeywordSuffix ),
						placeholder_string = placeholderKeywordSuffix,
						value = bind { key = propDecorateLabelValue },
						immediate = true,
						width_in_chars = 10,
					},
					f:edit_field {
						visible = LrBinding.keyEquals( propDecorateLabelKeyword, decorateKeywordParent ),
						placeholder_string = placeholderKeywordParent,
						value = bind { key = propDecorateLabelValue },
						immediate = true,
						width_in_chars = 10,
					},
				},
				f:row {
					fill_horizontal = 1,
					f:static_text {
						title = LOC( "$$$/RoboTagger/Options/Labels/Keywords/Arrow=^U+25B6" )
					},
					f:static_text {
						title = bind {
							keys = { propDecorateLabelKeyword, propDecorateLabelValue },
							operation = function( binder, values, fromTable )
								return renderSampleKeyword(
									values[ propDecorateLabelKeyword ],
									values[ propDecorateLabelValue ] )
							end,
						},
						font = "Courier",
						text_color = LrColor( 0, 0, 1 ),
					},
				},
			},
		},
		-- landmark options
		{
			bind_to_object = propertyTable,
			title = LOC( "$$$/RoboTagger/Options/Landmarks/Title=Landmark Options" ),
			spacing = f:control_spacing(),
			f:row {
				fill_horizontal = 1,
				f:static_text {
					title = LOC( "$$$/RoboTagger/Options/Landmarks/Threshold=Score Threshold:" ),
					width = share( propLandmarkOptionsPromptWidth ),
					alignment = "right",
				},
				f:edit_field {
					placeholder_string = LOC( "$$$/RoboTagger/Options/Landmarks/ThresholdPlaceHolder=<threshold>" ),
					value = bind { key = propLandmarkThreshold },
					immediate = true,
					min = thresholdMin,
					max = thresholdMax,
					increment = thresholdStep,
					precision = 0,
					width_in_digits = 4,
				},
				f:static_text {
					title = string.format( "%d%%", thresholdMin ),
					alignment = "right",
				},
				f:slider {
					fill_horizontal = 1,
					value = bind { key = propLandmarkThreshold },
					min = thresholdMin,
					max = thresholdMax,
					integral = thresholdStep,
				},
				f:static_text {
					title = string.format( "%d%%", thresholdMax ),
					alignment = "left",
				},
			},
			f:row {
				fill_horizontal = 1,
				f:static_text {
					title = LOC( "$$$/RoboTagger/Options/Landmarks/Keywords/Prompt=Create Keywords:" ),
					width = share( propLandmarkOptionsPromptWidth ),
					alignment = "right",
				},
				f:popup_menu {
					value = bind { key = propDecorateLandmarkKeyword },
					items = {
						{ title = titleKeywordAsIs,   value = decorateKeywordAsIs   },
						{ title = titleKeywordPrefix, value = decorateKeywordPrefix },
						{ title = titleKeywordSuffix, value = decorateKeywordSuffix },
						{ title = titleKeywordParent, value = decorateKeywordParent },
					},
				},
				f:row {
					place = "overlapping",
					fill_horizontal = 0.5,
					f:edit_field {
						visible = LrBinding.keyEquals( propDecorateLandmarkKeyword, decorateKeywordPrefix ),
						placeholder_string = placeholderKeywordPrefix,
						value = bind { key = propDecorateLandmarkValue },
						immediate = true,
						width_in_chars = 10,
					},
					f:edit_field {
						visible = LrBinding.keyEquals( propDecorateLandmarkKeyword, decorateKeywordSuffix ),
						placeholder_string = placeholderKeywordSuffix,
						value = bind { key = propDecorateLandmarkValue },
						immediate = true,
						width_in_chars = 10,
					},
					f:edit_field {
						visible = LrBinding.keyEquals( propDecorateLandmarkKeyword, decorateKeywordParent ),
						placeholder_string = placeholderKeywordParent,
						value = bind { key = propDecorateLandmarkValue },
						immediate = true,
						width_in_chars = 10,
					},
				},
				f:row {
					fill_horizontal = 1,
					f:static_text {
						title = LOC( "$$$/RoboTagger/Options/Landmarks/Keywords/Arrow=^U+25B6" )
					},
					f:static_text {
						title = bind {
							keys = { propDecorateLandmarkKeyword, propDecorateLandmarkValue },
							operation = function( binder, values, fromTable )
								return renderSampleKeyword(
									values[ propDecorateLandmarkKeyword ],
									values[ propDecorateLandmarkValue ] )
							end,
						},
						font = "Courier",
						text_color = LrColor( 0, 0, 1 ),
					},
				},
			},
			f:row {
				fill_horizontal = 1,
				f:checkbox {
					title = LOC( "$$$/RoboTagger/Options/Landmarks/CopyLocation=Copy Top Landmark Location (GPS coordinates)" ),
					value = bind { key = propLandmarkCopyLocation },
					fill_horizontal = 1,
				},
			},
		},
		-- credentials
		{
			bind_to_object = propertyTable,
			title = LOC( "$$$/RoboTagger/Credentials/Title=Google Cloud Credentials" ),
			synopsis = bind {
				key = propClientEmail,
				object = propertyTable,
			},
			spacing = f:control_spacing(),
			f:row {
				f:static_text {
					title = LOC( "$$$/RoboTagger/Credentials/ClientEmail=Client Email:" ),
					width = share( propCredentialsPromptWidth ),
					alignment = "right",
				},
				f:edit_field {
					placeholder_string = LOC( "$$$/RoboTagger/Credentials/ClientEmailPlaceHolder=<client email>" ),
					value = bind { key = propClientEmail },
					fill_horizontal = 1,
				},
			},
			f:row {
				f:static_text {
					title = LOC( "$$$/RoboTagger/Credentials/ServiceKey=Service Key:" ),
					width = share( propCredentialsPromptWidth ),
					alignment = "right",
				},
				f:password_field {
					-- yikes! do not make a password_field more than one line high.
					-- on Windows, that will turn into a regular edit_field, with content visible and copyable!
					placeholder_string = LOC( "$$$/RoboTagger/Credentials/ServiceKeyPlaceHolder=<service key>" ),
					value = bind { key = propServiceKey },
					fill_horizontal = 1,
					height_in_lines = 1,
				},
			},
			f:row {
				f:push_button {
					title = LOC( "$$$/RoboTagger/Credentials/Setup=Setup Instructions..." ),
					place_horizontal = 1,
					action = function( btn )
						LrHttp.openUrlInBrowser( "https://cloud.google.com/vision/docs/common/auth#set_up_a_service_account" )
					end,
				},
				f:push_button {
					title = LOC( "$$$/RoboTagger/Credentials/Load=Load Credentials..." ),
					place_horizontal = 1,
					action = function( btn )
						local fileName = LrDialogs.runOpenPanel( {
							title = LOC( "$$$/RoboTagger/OpenCredentialsFileTitle=Load Credentials From" ),
							canChooseFiles = true,
							canChooseDirectories = false,
							allowsMultipleSelection = false,
							initialDirectory = LrPathUtils.child( LrPathUtils.getStandardFilePath( "home" ), ".ssh" ),
						})

						if fileName then
							loadCredentials( propertyTable, fileName[1] )
						end
					end,
				},
				f:push_button {
					title = LOC( "$$$/RoboTagger/Credentials/Clear=Clear" ),
					place_horizontal = 1,
					action = function( btn )
						clearCredentials( propertyTable )
					end,
				},
			},
		},
		-- versions
		{
			bind_to_object = propertyTable,
			title = LOC( "$$$/RoboTagger/Versions/Title=Versions" ),
			synopsis = bind {
				key = propVersions,
				object = propertyTable,
				transform = function( value, fromTable )
					return value.vision.version
				end,
			},
			spacing = f:label_spacing(),
			f:row {
				f:static_text {
					title = LOC( "$$$/RoboTagger/Versions/GoogleVision/Arrow=^U+25B6" )
				},
				f:static_text {
					title = bind {
						key = propVersions,
						transform = function( value, fromTable )
							return value.vision.version
						end,
					},
					fill_horizontal = 1,
				},
			},
			f:row {
				f:static_text {
					title = LOC( "$$$/RoboTagger/Versions/OpenSSL/Arrow=^U+25B6" )
				},
				f:static_text {
					title = bind {
						key = propVersions,
						transform = function( value, fromTable )
							return value.openssl.version
						end,
					},
					fill_horizontal = 1,
				},
			},
		},
	}

end

--------------------------------------------------------------------------------

return {

	startDialog = startDialog,
	endDialog = endDialog,

	sectionsForTopOfDialog = sectionsForTopOfDialog,

}
