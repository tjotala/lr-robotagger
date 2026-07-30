--[[----------------------------------------------------------------------------

 RoboTagger
 Copyright 2017 Tapani Otala

--------------------------------------------------------------------------------

RoboTaggerMenuItem.lua

------------------------------------------------------------------------------]]

local LrApplication = import "LrApplication"
local LrPrefs = import "LrPrefs"
local LrTasks = import "LrTasks"
local LrHttp = import "LrHttp"
local LrDate = import "LrDate"
local LrColor = import "LrColor"
local LrStringUtils = import "LrStringUtils"
local LrFunctionContext = import "LrFunctionContext"
local LrProgressScope = import "LrProgressScope"
local LrDialogs = import "LrDialogs"
local LrBinding = import "LrBinding"
local LrView = import "LrView"
local bind = LrView.bind
local share = LrView.share

--------------------------------------------------------------------------------

local inspect = require "inspect"
require "Logger"
require "GoogleVisionAPI"

--------------------------------------------------------------------------------

local prefs = LrPrefs.prefsForPlugin()

local propLabelThreshold = "labelThreshold"
local propLandmarkThreshold = "landmarkThreshold"
local propPhotos = "photos"
local propCurrentPhotoIndex = "currentPhotoIndex"
local propCurrentPhotoName = "currentPhotoName"
local propTotalPhotos = "totalPhotos"
local propStartTime = "startTime"
local propElapsedTime = "elapsedTime"
local propConsumedTime = "consumedTime"
local propMaxLabels = "maxLabels"
local propMaxLandmarks = "maxLandmarks"

local function propLabelTitle( i )
	return string.format( "labelTitle%d", i )
end
local function propLabelScore( i )
	return string.format( "labelScore%d", i )
end
local function propLabelSelected( i )
	return string.format( "labelSelected%d", i )
end

local function propLandmarkTitle( i )
	return string.format( "landmarkTitle%d", i )
end
local function propLandmarkScore( i )
	return string.format( "landmarkScore%d", i )
end
local function propLandmarkSelected( i )
	return string.format( "landmarkSelected%d", i )
end
local function propLandmarkLocation( i )
	return string.format( "landmarkLocation%d", i )
end

--------------------------------------------------------------------------------

-- save photo from propertyTable[ propXXX ] to propertyTable.photos[ i ]
local function savePhoto( propertyTable, index )
	local photo = propertyTable[ propPhotos ][ index ]
	if photo ~= nil then
		logger:tracef( "saving label selections" )
		local labels = photo.labels or { }
		for i, label in ipairs( labels ) do
			label.selected = propertyTable[ propLabelSelected( i ) ]
		end
		photo.labelThreshold = propertyTable[ propLabelThreshold ]

		logger:tracef( "saving landmark selections" )
		local landmarks = photo.landmarks or { }
		for i, landmark in ipairs( landmarks ) do
			landmark.selected = propertyTable[ propLandmarkSelected( i ) ]
		end
		photo.landmarkThreshold = propertyTable[ propLandmarkThreshold ]
	end
end

-- load photo from propertyTable.photos[ i ] to propertyTable[ propXXX ]
local function loadPhoto( propertyTable, index )
	local photo = propertyTable[ propPhotos ][ index ]
	assert( photo ~= nil )

	local labels = photo.labels or { }
	logger:tracef( "updating %d labels", #labels )
	for i = 1, prefs.maxLabels do
		local label = labels[ i ] or { description = nil, score = 0, selected = false }
		propertyTable[ propLabelTitle( i ) ] = label.description
		propertyTable[ propLabelScore( i ) ] = label.score
		propertyTable[ propLabelSelected( i ) ] = label.selected
	end
	propertyTable[ propLabelThreshold ] = photo.labelThreshold

	local landmarks = photo.landmarks or { }
	logger:tracef( "updating %d landmarks", #landmarks )
	for i = 1, prefs.maxLandmarks do
		local landmark = landmarks[ i ] or { description = nil, score = 0, locations = { { latLng = { } } }, selected = false }
		propertyTable[ propLandmarkTitle( i ) ] = landmark.description
		propertyTable[ propLandmarkScore( i ) ] = landmark.score
		propertyTable[ propLandmarkLocation( i ) ] = landmark.locations[1].latLng
		propertyTable[ propLandmarkSelected( i ) ] = landmark.selected
	end
	propertyTable[ propLandmarkThreshold ] = photo.landmarkThreshold
end

-- select photo (i.e. move from index X to Y)
local function selectPhoto( propertyTable, newIndex )
	logger:tracef( "selecting photo %d of %d", newIndex, #propertyTable[ propPhotos ] )

	local oldIndex = propertyTable[ propCurrentPhotoIndex ]
	if oldIndex ~= newIndex then
		savePhoto( propertyTable, oldIndex )
	end

	loadPhoto( propertyTable, newIndex )
	propertyTable[ propCurrentPhotoIndex ] = newIndex
end

-- apply the selected labels and landmarks to the photo
local function applyKeywordsToPhoto( photo, labels, landmarks )
	local catalog = photo.catalog
	catalog:withWriteAccessDo(
		LOC( "$$$/RoboTagger/ActionName=Apply Keywords " ),
		function()
			local function createDecoratedKeyword( name, decoration, value )
				local parent = nil
				if decoration == decorateKeywordParent then
					parent = catalog:createKeyword( value, nil, true, nil, true )
					if parent == nil then
						logger:errorf( "failed to add parent keyword %s", value )
						return nil
					end
				end
				if decoration == decorateKeywordPrefix then
					name = string.format( "%s %s", value, name )
				elseif decoration == decorateKeywordSuffix then
					name = string.format( "%s %s", name, value )
				else
					 -- decorateKeywordAsIs or decorateKeywordParent, do nothing
				end
				logger:tracef( "creating keyword %s", name )
				return catalog:createKeyword( name, nil, true, parent, true )
			end

			-- logger:tracef( "applying label keywords to %s: %s", photo:getFormattedMetadata( "fileName" ), inspect( labels ) )
			for _, label in ipairs( labels ) do
				if label.selected then
					local keyword = createDecoratedKeyword( label.description, prefs.decorateLabelKeyword, prefs.decorateLabelValue )
					if keyword then
						photo:addKeyword( keyword )
					else
						logger:errorf( "failed to add keyword %s", name )
					end
				end
			end

			-- logger:tracef( "applying landmark keywords to %s: %s", photo:getFormattedMetadata( "fileName" ), inspect ( landmarks ) )
			for i, landmark in ipairs( landmarks ) do
				if landmark.selected then
					local keyword = createDecoratedKeyword( landmark.description, prefs.decorateLandmarkKeyword, prefs.decorateLandmarkValue )
					if keyword then
						photo:addKeyword( keyword )
					else
						logger:errorf( "failed to add keyword %s", name )
					end

					if i == 1 and prefs.landmarkCopyLocation then
						-- only clobber GPS location if this is the highest confidence result
						local location = landmark.locations[1].latLng
						photo:setRawMetadata( "gps", { latitude = location.latitude, longitude = location.longitude } )
					end
				end
			end
			-- logger:tracef( "done applying keywords to %s", photo:getFormattedMetadata( "fileName" ) )
		end
	)
end

local function showResponse( propertyTable )

	local function formatScore( score )
		return string.format( "(%.01f%%)", score * 100 )
	end

	local function formatPct( pct )
		return string.format( "%d%%", pct )
	end

	local f = LrView.osFactory()

	-- create labels array
	local labels = { }
	for i = 1, prefs.maxLabels do
		local propTitle = propLabelTitle( i )
		local propScore = propLabelScore( i )
		local propSelected = propLabelSelected( i )
		table.insert( labels,
			f:row {
				f:checkbox {
					visible = LrBinding.keyIsNotNil( propTitle ),
					title = bind { key = propTitle },
					value = bind { key = propSelected },
					width = 200,
				},
				f:static_text {
					visible = LrBinding.keyIsNotNil( propTitle ),
					title = bind {
						key = propScore,
						transform = function( value, fromTable )
							return formatScore( value )
						end,
					},
					width = 50,
					alignment = "right",
				},
			}
		)
	end
	table.insert( labels,
		f:column {
			fill_horizontal = 1,
			f:spacer {
				height = 4,
			},
			f:separator {
				fill_horizontal = 1,
			},
			f:spacer {
				height = 4,
			},
			f:row {
				f:static_text {
					title = formatPct( thresholdMin ),
				},
				f:column {
					fill_horizontal = 1,
					f:slider {
						enabled = LrBinding.keyIsNotNil( propLabelTitle( 1 ) ),
						fill_horizontal = 1,
						value = bind {
							key = propLabelThreshold,
							transform = function( value, fromTable )
								if not fromTable then
									-- user is tweaking UI
									for i = 1, prefs.maxLabels do
										propertyTable[ propLabelSelected( i ) ] = propertyTable[ propLabelScore( i ) ] * 100 >= value
									end
								end
								return value
							end,
						},
						min = thresholdMin,
						max = thresholdMax,
						integral = thresholdStep,
					},
					f:static_text {
						title = bind {
							key = propLabelThreshold,
							transform = function( value, fromTable )
								return formatPct( value )
							end
						},
						fill_horizontal = 1,
						alignment = "center",
					},
				},
				f:static_text {
					title = formatPct( thresholdMax ),
				},
			}
		}
	)

	-- create landmarks array
	local landmarks = { }
	for i = 1, prefs.maxLandmarks do
		local propTitle = propLandmarkTitle( i )
		local propScore = propLandmarkScore( i )
		local propLocation = propLandmarkLocation( i )
		local propSelected = propLandmarkSelected( i )
		table.insert( landmarks,
			f:row {
				f:checkbox {
					visible = LrBinding.keyIsNotNil( propTitle ),
					title = bind { key = propTitle },
					value = bind { key = propSelected },
					width = 200,
				},
				f:static_text {
					visible = LrBinding.keyIsNotNil( propTitle ),
					title = LOC( "$$$/RoboTagger/ViewGpsCoordinates=^U+27B6" ),
					tooltip = bind {
						key = propLocation,
						transform = function( value, fromTable )
							local lat = value.latitude
							local lon = value.longitude
							return string.format( "%f,%f", lat, lon )
						end,
					},
					mouse_down = function( btn )
						local lat = propertyTable[ propLocation ].latitude
						local lon = propertyTable[ propLocation ].longitude
						LrHttp.openUrlInBrowser( string.format( "https://maps.google.com/?q=@%f,%f", lat, lon ) )
					end
				},
				f:static_text {
					visible = LrBinding.keyIsNotNil( propTitle ),
					title = bind {
						key = propScore,
						transform = function( value, fromTable )
							return formatScore( value )
						end
					},
					width = 50,
					alignment = "right"
				},
			}
		)
	end
	table.insert( landmarks,
		f:column {
			fill_horizontal = 1,
			f:spacer {
				height = 4,
			},
			f:separator {
				fill_horizontal = 1,
			},
			f:spacer {
				height = 4,
			},
			f:row {
				f:static_text {
					title = formatPct( thresholdMin ),
				},
				f:column {
					fill_horizontal = 1,
					f:slider {
						enabled = LrBinding.keyIsNotNil( propLandmarkTitle( 1 ) ),
						fill_horizontal = 1,
						value = bind {
							key = propLandmarkThreshold,
							transform = function( value, fromTable )
								if not fromTable then
									-- user is tweaking UI
									for i = 1, prefs.maxLandmarks do
										propertyTable[ propLandmarkSelected( i ) ] = propertyTable[ propLandmarkScore( i ) ] * 100 >= value
									end
								end
								return value
							end,
						},
						min = thresholdMin,
						max = thresholdMax,
						integral = thresholdStep,
					},
					f:static_text {
						title = bind {
							key = propLandmarkThreshold,
							transform = function( value, fromTable )
								return formatPct( value )
							end
						},
						fill_horizontal = 1,
						alignment = "center",
					},
				},
				f:static_text {
					title = formatPct( thresholdMax ),
				},
			}
		}
	)

	propertyTable:addObserver( propPhotos,
		function( propertyTable, key, value )
			if #value > 0 and propertyTable[ propCurrentPhotoIndex ] == 0 then
				logger:tracef( "making the initial selection" )
				selectPhoto( propertyTable, 1 )
			end
		end
	)

	propertyTable:addObserver( propCurrentPhotoIndex,
		function( propertyTable, key, value )
			LrTasks.startAsyncTask(
				function()
					local photo = propertyTable[ propPhotos ][ value ].photo
					propertyTable[ propCurrentPhotoName ] = photo:getFormattedMetadata( "fileName" )
				end
			)
		end
	)

	local contents = f:column {
		bind_to_object = propertyTable,
		spacing = f:dialog_spacing(),
		fill_horizontal = 1,
		place_horizontal = 0.5,
		f:column {
			fill_horizontal = 1,
			place_horizontal = 0.5,
			f:row {
				f:push_button {
					title = LOC( "$$$/RoboTagger/PrevPhoto=^U+25C0" ),
					fill_horizontal = 0.25,
					place_vertical = 0.5,
					enabled = bind {
						key = propCurrentPhotoIndex,
						transform = function( value, fromTable )
							return value > 1
						end,
					},
					action = function( btn )
						logger:tracef( "previous photo" )
						selectPhoto( propertyTable, propertyTable[ propCurrentPhotoIndex ] - 1 )
					end,
				},
				f:catalog_photo {
					visible = LrBinding.keyIsNot( propCurrentPhotoIndex, 0 ),
					photo = bind {
						key = propCurrentPhotoIndex,
						transform = function( value, fromTable )
							if value > 0 then
								return propertyTable[ propPhotos ][ value ].photo
							end
							return nil
						end,
					},
					width = 400,
					height = 300,
					fill_horizontal = 0.5,
					place_horizontal = 0.5,
					frame_width = 0,
					frame_color = LrColor(), -- alpha = 0
					background_color = LrColor(), -- alpha = 0
				},
				f:push_button {
					title = LOC( "$$$/RoboTagger/NextPhoto=^U+25B6" ),
					fill_horizontal = 0.25,
					place_vertical = 0.5,
					enabled = bind {
						keys = { propCurrentPhotoIndex, propPhotos },
						operation = function( binder, values, fromTable )
							local i = values [ propCurrentPhotoIndex ]
							return values[ propPhotos ][ i + 1 ] ~= nil
						end,
					},
					action = function( btn )
						local i = propertyTable [ propCurrentPhotoIndex ]
						logger:tracef( "next photo: %d", i + 1 )
						selectPhoto( propertyTable, i + 1 )
					end,
				},
			},
			f:static_text {
				visible = LrBinding.keyIsNot( propCurrentPhotoIndex, 0 ),
				title = bind {
					keys = { propCurrentPhotoIndex, propCurrentPhotoName, propPhotos },
					operation = function( binder, values, fromTable )
						return LOC( "$$$/RoboTagger/PhotoXofY=Photo ^1 of ^2: ^3 (^4 sec)",
							LrStringUtils.numberToStringWithSeparators( values[ propCurrentPhotoIndex ], 0 ),
							LrStringUtils.numberToStringWithSeparators( #values[ propPhotos ], 0 ),
							values[ propCurrentPhotoName ],
							LrStringUtils.numberToStringWithSeparators( values[ propPhotos ][ values[ propCurrentPhotoIndex ] ].elapsed, 2 ) )
					end,
				},
				fill_horizontal = 1,
				alignment = "center"
			},
			f:static_text {
				title = bind {
					key = propPhotos,
					transform = function( value, fromTable )
						local numPhotos = #value
						local remPhotos = propertyTable[ propTotalPhotos ] - numPhotos
						local consumedTime = propertyTable[ propConsumedTime ]
						local elapsedTime = propertyTable[ propElapsedTime ]
						if remPhotos > 0 then
							if #value > 0 then
								-- use elapsedTime rather than consumedTime to factor in parallelization
								local remTime = math.ceil( elapsedTime / numPhotos * remPhotos )
								return LOC( "$$$/RoboTagger/PhotosRemaining=^1 photos to analyze, estimated completion in ^2 sec (^3 sec elapsed)",
									LrStringUtils.numberToStringWithSeparators( remPhotos, 0 ),
									LrStringUtils.numberToStringWithSeparators( remTime, 0 ),
									LrStringUtils.numberToStringWithSeparators( elapsedTime, 2 ) )
							else
								return LOC( "$$$/RoboTagger/PhotosRemaining=^1 photos to analyze",
									LrStringUtils.numberToStringWithSeparators( remPhotos, 0 ) )
							end
						else
							return LOC( "$$$/RoboTagger/PhotosRemaining=^1 photos analyzed in ^2 sec (^3 sec elapsed)",
								LrStringUtils.numberToStringWithSeparators( numPhotos, 0 ),
								LrStringUtils.numberToStringWithSeparators( consumedTime, 2 ),
								LrStringUtils.numberToStringWithSeparators( elapsedTime, 2 ) )
						end
					end,
				},
				fill_horizontal = 1,
				alignment = "center"
			},
		},
		f:row {
			f:group_box {
				title = LOC( "$$$/RoboTagger/ResultsDialogLabelTitle=Labels" ),
				font = "<system/bold>",
				f:row {
					place = "overlapping",
					f:column {
						f:static_text {
							visible = LrBinding.keyIsNil( propLabelTitle( 1 ) ),
							title = LOC( "$$$/RoboTagger/NoLabels=None" ),
							fill_horizontal = 1,
						},
					},
					f:column( labels ),
				},
			},
			f:group_box {
				title = LOC( "$$$/RoboTagger/ResultsDialogLandmarkTitle=Landmarks" ),
				font = "<system/bold>",
				f:row {
					place = "overlapping",
					f:column {
						f:static_text {
							visible = LrBinding.keyIsNil( propLandmarkTitle( 1 ) ),
							title = LOC( "$$$/RoboTagger/NoLandmarks=None" ),
							fill_horizontal = 1,
						},
					},
					f:column( landmarks ),
				},
			},
		},
		f:row {
			fill_horizontal = 1,
			f:push_button {
				enabled = LrBinding.keyIsNot( propCurrentPhotoIndex, 0 ),
				title = LOC( "$$$/RoboTagger/ResultsDialogApply=Apply" ),
				place_horizontal = 1,
				action = function()
					LrTasks.startAsyncTask(
						function()
							savePhoto( propertyTable, propertyTable[ propCurrentPhotoIndex ])
							local photo = propertyTable[ propPhotos ][ propertyTable[ propCurrentPhotoIndex ] ]
							applyKeywordsToPhoto( photo.photo, photo.labels, photo.landmarks )
						end
					)
				end,
			},
			f:push_button {
				enabled = LrBinding.keyIsNot( propCurrentPhotoIndex, 0 ),
				title = LOC( "$$$/RoboTagger/ResultsDialogApplyAll=Apply All" ),
				place_horizontal = 1,
				action = function()
					LrTasks.startAsyncTask(
						function()
							savePhoto( propertyTable, propertyTable[ propCurrentPhotoIndex ])
							for _, photo in ipairs( propertyTable[ propPhotos ] ) do
								applyKeywordsToPhoto( photo.photo, photo.labels, photo.landmarks )
							end
						end
					)
				end,
			}
		},
	}
	local results = LrDialogs.presentModalDialog {
		title = LOC( "$$$/RoboTagger/ResultsDialogTitle=RoboTagger: Google Vision Results" ),
		resizable = false,
		contents = contents,
		actionVerb = LOC( "$$$/RoboTagger/ResultsDialogOk=Done" ),
		cancelVerb = "< exclude >", -- magic value to hide the Cancel button
	}
end

local function RoboTagger()
	LrFunctionContext.postAsyncTaskWithContext( "analyzing photos",
		function( context )
			logger:tracef( "RoboTaggerMenuItem v2.0: enter" )
			LrDialogs.attachErrorDialogToFunctionContext( context )
			local catalog = LrApplication.activeCatalog()

			-- Authenticate with Google Vision using updated OAuth2 endpoint
			local auth = GoogleVisionAPI.authenticate()
			if not auth.status then
				logger:errorf( "failed to authenticate to Google Vision API: %s", auth.message )
				local errorMsg = string.format( "Authentication failed: %s\n\nPlease check:\n• Google Cloud credentials are properly configured\n• Vision API is enabled in Google Cloud Console\n• Service account has necessary permissions", auth.message )
				LrDialogs.message( LOC( "$$$/RoboTagger/AuthFailed=Failed to authenticate to Google Vision API" ), errorMsg, "critical" )
			else
				local propertyTable = LrBinding.makePropertyTable( context )
				local photos = catalog:getTargetPhotos()

				propertyTable[ propPhotos ] = { }
				propertyTable[ propCurrentPhotoIndex ] = 0
				propertyTable[ propTotalPhotos ] = #photos
				propertyTable[ propStartTime ] = LrDate.currentTime()
				propertyTable[ propElapsedTime ] = 0 -- elapsed wall time
				propertyTable[ propConsumedTime ] = 0 -- consumed CPU time
				propertyTable[ propLabelThreshold ] = prefs.labelThreshold
				propertyTable[ propLandmarkThreshold ] = prefs.landmarkThreshold

				local progressScope = LrProgressScope {
					title = LOC( "$$$/RoboTagger/ProgressScopeTitle=Analyzing Photos" ),
					functionContext = context
				}
				progressScope:setCancelable( true )

				-- show the progress dialog, as an async task
				local inDialog = true
				LrTasks.startAsyncTask(
					function()
						showResponse( propertyTable )
						inDialog = false
						progressScope:done()
					end
				)

				-- Enumerate through all selected photos in the catalog
				local runningTasks = 0
				local thumbnailRequests = { }
				logger:tracef( "begin analyzing %d photos", #photos )
				for i, photo in ipairs( photos ) do
					if progressScope:isCanceled() or progressScope:isDone() then
						break
					end

					-- Update the progress bar
					local fileName = photo:getFormattedMetadata( "fileName" )
					progressScope:setCaption( LOC( "$$$/RoboTagger/ProgressCaption=^1 (^2 of ^3)", fileName, i, #photos ) )
					progressScope:setPortionComplete( i, #photos )

					local function trace( msg, ... )
						logger:tracef( "[%d | %d | %s] %s", #photos, i, fileName, string.format( msg, unpack( arg ) ) )
					end

					while ( runningTasks >= prefs.maxTasks ) and not ( progressScope:isCanceled() or progressScope:isDone() ) do
						-- logger:tracef( "%d analysis tasks running, waiting for one to finish", runningTasks )
						LrTasks.sleep( 0.2 )
					end
					runningTasks = runningTasks + 1

					trace( "begin analysis" )
					table.insert( thumbnailRequests, i, photo:requestJpegThumbnail( prefs.thumbnailWidth, prefs.thumbnailHeight,
						function( jpegData, errorMsg )
							LrTasks.startAsyncTask(
								function()
									if jpegData then
										trace( "analyzing thumbnail (%s bytes)", LrStringUtils.numberToStringWithSeparators( #jpegData, 0 ) )
										local start = LrDate.currentTime()
										local result = GoogleVisionAPI.analyze( fileName, jpegData, prefs.maxLabels, prefs.maxLandmarks )
										local elapsed = LrDate.currentTime() - start
										if result.status then
											for _, label in ipairs( result.labels ) do
												label.selected = label.score * 100 >= propertyTable[ propLabelThreshold ]
											end
											for _, landmark in ipairs( result.landmarks ) do
												landmark.selected = landmark.score * 100 >= propertyTable[ propLandmarkThreshold ]
											end
											trace( "completed in %.03f sec, got %d labels and %d landmarks", elapsed, #result.labels, #result.landmarks )
											-- trace( "labels: %s", inspect( result.labels ) )
											-- trace( "landmarks: %s", inspect( result.landmarks ) )
											propertyTable[ propPhotos ][ i ] = {
												photo = photo,
												labels = result.labels,
												landmarks = result.landmarks,
												elapsed = elapsed,
												labelThreshold = propertyTable[ propLabelThreshold ],
												landmarkThreshold = propertyTable[ propLandmarkThreshold ],
											}
											propertyTable[ propConsumedTime ] = propertyTable[ propConsumedTime ] + elapsed
											propertyTable[ propElapsedTime ] = LrDate.currentTime() - propertyTable[ propStartTime ]
											propertyTable[ propPhotos ] = propertyTable[ propPhotos ] -- dummy assignment to trigger bindings
										else
											local action = LrDialogs.confirm( LOC( "$$$/RoboTagger/FailedAnalysis=Failed to analyze photo ^1", fileName ), result.message )
											if action == "cancel" then
												progressScope:cancel()
											end
										end
									else
										local action = LrDialogs.confirm( LOC( "$$$/RoboTagger/FailedThumbnail=Failed to generate thumbnail for ^1", fileName ), errorMsg )
										if action == "cancel" then
											progressScope:cancel()
										end
									end
									table.remove( thumbnailRequests, i )
									runningTasks = runningTasks - 1
									trace( "end analysis" )
								end
							)
						end
					) )

					LrTasks.yield()
				end

				while runningTasks > 0 do
					logger:tracef( "waiting for %d analysis tasks to finish", runningTasks )
					LrTasks.sleep( 0.2 )
				end
				thumbnailRequests = nil
				progressScope:done()

				logger:tracef( "done analyzing %d photos in %.02f sec (%.02f sec elapsed)", #photos, propertyTable[ propConsumedTime ], propertyTable[ propElapsedTime ] )

				while inDialog do
					LrTasks.sleep( 1 )
				end
			end

			logger:tracef( "RoboTaggerMenuItem: exit" )
		end
	)
end

--------------------------------------------------------------------------------
-- Begin the search
RoboTagger()
