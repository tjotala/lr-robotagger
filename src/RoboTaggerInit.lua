--[[----------------------------------------------------------------------------

 RoboTagger
 Copyright 2017-2024 Tapani Otala
 Updated for Lightroom Classic 2024

--------------------------------------------------------------------------------

RoboTaggerInit.lua

------------------------------------------------------------------------------]]

local LrSystemInfo = import "LrSystemInfo"
local LrPrefs = import "LrPrefs"

--------------------------------------------------------------------------------

require "Logger"

--------------------------------------------------------------------------------

logger:tracef( "RoboTagger v2.0: init for Lightroom Classic 2024" )

local prefs = LrPrefs.prefsForPlugin()

decorateKeywordAsIs   = "keywordAsIs"
decorateKeywordPrefix = "keywordPrefix"
decorateKeywordSuffix = "keywordSuffix"
decorateKeywordParent = "keywordParent"

thresholdMin = 0
thresholdMax = 100
thresholdStep = 1

tasksMin = 1
logger:tracef( "system has %d CPUs", LrSystemInfo.numCPUs() )
tasksMax = LrSystemInfo.numCPUs()
tasksStep = 1

if prefs.maxTasks == nil then
	prefs.maxTasks = math.min(tasksMax, 4) -- Limit to 4 concurrent requests for better stability
end

prefs.maxLabels = 10
prefs.maxLandmarks = 10
-- Increase thumbnail size for better accuracy with modern Vision API
prefs.thumbnailWidth = 1600
prefs.thumbnailHeight = 1600

if prefs.labelThreshold == nil then
	prefs.labelThreshold = 80
end
if prefs.decorateLabelKeyword == nil then
	prefs.decorateLabelKeyword = decorateKeywordAsIs
	prefs.decorateLabelValue = nil
end

if prefs.landmarkThreshold == nil then
	prefs.landmarkThreshold = 80
end
if prefs.landmarkCopyLocation == nil then
	prefs.landmarkCopyLocation = true
end

if prefs.decorateLandmarkKeyword == nil then
	prefs.decorateLandmarkKeyword = decorateKeywordAsIs
	prefs.decorateLandmarkValue = nil
end
