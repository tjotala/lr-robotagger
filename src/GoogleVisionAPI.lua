--[[----------------------------------------------------------------------------

 RoboTagger
 Copyright 2017-2024 Tapani Otala
 Updated for Lightroom Classic 2024 and latest Google Vision API

--------------------------------------------------------------------------------

GoogleVisionAPI.lua

------------------------------------------------------------------------------]]

local LrPrefs = import "LrPrefs"
local LrPasswords = import "LrPasswords"
local LrFileUtils = import "LrFileUtils"
local LrPathUtils = import "LrPathUtils"
local LrStringUtils = import "LrStringUtils"
local LrDate = import "LrDate"
local LrShell = import "LrShell"
local LrHttp = import "LrHttp"

--------------------------------------------------------------------------------

local JSON = require "JSON"
local inspect = require "inspect"
require "Logger"

function JSON.assert(exp, message)
	-- just log the decode error, let the decoder return nil
	logger:errorf( "JSON parse error: %s", message )
end

--------------------------------------------------------------------------------
-- Google Vision API

GoogleVisionAPI = { }

local httpContentType = "Content-Type"
local httpAuthorization = "Authorization"
local httpAccept = "Accept"

local mimeTypeForm = "application/x-www-form-urlencoded"
local mimeTypeJson = "application/json"

local keyCredentials = "GoogleCloudPlatform.Credentials"
local keyToken = "GoogleCloudPlatform.Token"

local serviceScope = "https://www.googleapis.com/auth/cloud-platform"
local serviceGrantType = "urn:ietf:params:oauth:grant-type:jwt-bearer"
local serviceTokenUri = "https://oauth2.googleapis.com/token"
local serviceAnalyzeUri = "https://vision.googleapis.com/v1/images:annotate"

local serviceTokenTTL = 60 * 60 -- 1hr is the max TTL
local serviceMaxRetries = 2

local tempPath = LrPathUtils.getStandardFilePath( "temp" )
local tempBaseName = "robotagger.tmp"

--------------------------------------------------------------------------------

local function createTempFile( baseName, contents )
	local fileName = LrFileUtils.chooseUniqueFileName( LrPathUtils.child( tempPath, baseName ) )
	local file = io.open( fileName, "w" )
	if file then
		file:write( contents )
		file:close()
		return fileName
	end
	return nil
end

local function readJsonFile( fileName )
	return JSON:decode( LrFileUtils.readFile( fileName ) )
end

local function urlEncode( str )
	return string.gsub( str, "([^%w ])",
		function (c)
			return string.format( "%%%02X", string.byte( c ) )
		end
	)
end

-- create a JSON Web Token (JWT) of the form:
--     header.payload.signature
-- where:
--     header: {"alg":"RS256","typ":"JWT"}, base64-encoded
--     payload: claims request (see Google docs), base64-encoded
--     signature: RSASSA-PKCS1-V1_5-SIGN signature over "header.payload", base64-encoded
-- see:
--     https://developers.google.com/identity/protocols/OAuth2ServiceAccount
local function createJWT( serviceInfo )
	local now = math.floor( LrDate.timeToPosixDate( LrDate.currentTime() ) )
	local header = JSON:encode {
		alg = "RS256",
		typ = "JWT"
	}
	local claims = JSON:encode {
		iss = serviceInfo.client_email,
		scope = serviceScope,
		aud = serviceTokenUri,
		iat = now,
		exp = now + serviceTokenTTL
	}
	local payload = string.format( "%s.%s", LrStringUtils.encodeBase64( header ), LrStringUtils.encodeBase64( claims ) )

	local jwt = nil
	local keyFileName = createTempFile( tempBaseName, serviceInfo.private_key )
	if keyFileName then
		-- logger:tracef( "created %s for key", keyFileName )
		local payloadFileName = createTempFile( tempBaseName, payload )
		if payloadFileName then
			-- logger:tracef( "created %s for payload", payloadFileName )
			local signatureFile = io.popen( string.format( "openssl dgst -sha256 -sign %s -binary %s", keyFileName, payloadFileName ), "r" )
			if signatureFile then
				local signature = signatureFile:read( "*a" )
				signatureFile:close()
				if #signature > 0 then
					-- logger:tracef( "signed: %s", signature )
					jwt = string.format( "%s.%s", payload, LrStringUtils.encodeBase64( signature ) )
				else
					logger:errorf( "failed to sign with OpenSSL" )
				end
			else
				logger:errorf( "failed to sign with OpenSSL" )
			end


			LrFileUtils.delete( payloadFileName )
		else
			logger:errorf( "failed to open temp file for payload: %s", payloadFileName )
		end

		LrFileUtils.delete( keyFileName )
	else
		logger:errorf( "failed to open temp file for key: %s", keyFileName )
	end
	return jwt
end

--------------------------------------------------------------------------------

function GoogleVisionAPI.getVersions()
	versions = { }

	-- Use a simpler approach since the discovery endpoint may not be reliable
	local response = LrHttp.get( "https://vision.googleapis.com/$discovery/rest?version=v1" )
	if response then
		local ver = JSON:decode( response )
		-- logger:tracef( "got Google Vision version: %s", inspect( ver ) )
		if ver and ver.title and ver.version then
			versions.vision = {
				version = string.format( "%s %s", ver.title, ver.version ),
				icon = ver.icons and ver.icons.x32 or nil,
			}
		else
			versions.vision = {
				version = "Google Cloud Vision API v1 (2024)",
			}
		end
	else
		versions.vision = {
			version = "Google Cloud Vision API v1 (2024)",
		}
	end

	local pipe = io.popen( "openssl version", "r" )
	if pipe then
		local ver = pipe:read( "*l" )
		if ver then
			-- logger:tracef( "got OpenSSL version: %s", ver )
			versions.openssl = {
				version = ver,
			}
		else
			versions.openssl = {
				error = LOC( "$$$/GoogleVisionAPI/NoOpenSSL=Unable to get OpenSSL version!" )
			}
		end
		pipe:close()
	else
		versions.openssl = {
			error = LOC( "$$$/GoogleVisionAPI/NoOpenSSL=OpenSSL not found!" )
		}
	end

	return versions
end

function GoogleVisionAPI.storeCredentials( credentials )
	math.randomseed( LrDate.currentTime() )
	local salt = tostring( math.random() * 100000 )
	local prefs = LrPrefs.prefsForPlugin()
	prefs.salt = salt
	LrPasswords.store( keyCredentials, JSON:encode( credentials ), salt )
end

function GoogleVisionAPI.clearCredentials()
	local prefs = LrPrefs.prefsForPlugin()
	prefs.salt = nil
	LrPasswords.store( keyCredentials, "" )
	GoogleVisionAPI.clearToken() -- trash any outstanding tokens too
end

function GoogleVisionAPI.getCredentials()
	local prefs = LrPrefs.prefsForPlugin()
	local salt = prefs.salt
	local creds = LrPasswords.retrieve( keyCredentials, salt )
	return JSON:decode( creds )
end

function GoogleVisionAPI.hasCredentials()
	return GoogleVisionAPI.getCredentials() ~= nil
end

function GoogleVisionAPI.loadCredentialsFromFile( fileName )
	return readJsonFile( fileName )
end

function GoogleVisionAPI.storeToken( token )
	LrPasswords.store( keyToken, JSON:encode( token ) )
end

function GoogleVisionAPI.clearToken()
	LrPasswords.store( keyToken, "" )
end

function GoogleVisionAPI.getToken()
	local token = LrPasswords.retrieve( keyToken )
	return JSON:decode( token )
end

--------------------------------------------------------------------------------

function GoogleVisionAPI.authenticate()
	local credentials = GoogleVisionAPI.getCredentials()
	if credentials then
		logger:tracef( "GoogleVisionAPI: authenticating with updated OAuth2 endpoint" )
		local jwt = createJWT( credentials )
		if jwt then
			local reqHeaders = {
				{ field = httpContentType, value = mimeTypeForm },
				{ field = httpAccept, value = mimeTypeJson },
			}
			local reqBody = string.format( "grant_type=%s&assertion=%s", urlEncode( serviceGrantType ), urlEncode( jwt ) )
			local resBody, resHeaders = LrHttp.post( serviceTokenUri, reqBody, reqHeaders )
			-- logger:tracef( "response body: %s", resBody )

			if resBody then
				local resJson = JSON:decode( resBody )
				if resHeaders.status == 200 and resJson then
					GoogleVisionAPI.storeToken( resJson )
					logger:tracef( "GoogleVisionAPI: authentication successful" )
					return { status = true }
				else
					local errorMsg = "Unknown authentication error"
					if resJson and resJson.error_description then
						errorMsg = resJson.error_description
					elseif resJson and resJson.error then
						errorMsg = resJson.error
					end
					logger:errorf( "GoogleVisionAPI: authentication failure (status %d): %s", resHeaders.status or 0, errorMsg )
					return { status = false, message = errorMsg }
				end
			else
				local errorMsg = "Network connection failed"
				if resHeaders and resHeaders.error then
					errorMsg = string.format( "%s (%d): %s", resHeaders.error.name or "Network Error", resHeaders.error.nativeCode or 0, resHeaders.error.errorCode or "Unknown" )
				end
				logger:errorf( "GoogleVisionAPI: network error: %s", errorMsg )
				return { status = false, message = errorMsg }
			end
		else
			logger:errorf( "GoogleVisionAPI: failed to create JWT token" )
			return { status = false, message = LOC( "$$$/GoogleVisionAPI/JWTFailed=Failed to create authentication token" ) }
		end
	end
	logger:errorf( "GoogleVisionAPI: authentication failure, missing credentials" )
	return { status = false, message = LOC( "$$$/GoogleVisionAPI/BadCredentials=Bad credentials" ) }
end

--------------------------------------------------------------------------------

function GoogleVisionAPI.analyze( fileName, photo, maxLabels, maxLandmarks )
	local attempts = 0
	while attempts <= serviceMaxRetries do
		local token = GoogleVisionAPI.getToken()
		if token then
			local reqHeaders = {
				{ field = httpAuthorization, value = string.format( "%s %s", token.token_type, token.access_token ) },
				{ field = httpContentType, value = mimeTypeJson },
				{ field = httpAccept, value = mimeTypeJson },
			}
			-- logger:tracef( "request headers: %s", inspect( reqHeaders ) )
			local reqBody = JSON:encode {
				requests = {
					{
						image = {
							content = LrStringUtils.encodeBase64( photo )
						},
						features = {
							{ type = "LABEL_DETECTION", maxResults = maxLabels },
							{ type = "LANDMARK_DETECTION", maxResults = maxLandmarks }
						}
					}
				}
			}
			-- logger:tracef( "request body: %s", reqBody )
			local resBody, resHeaders = LrHttp.post( serviceAnalyzeUri, reqBody, reqHeaders )
			-- logger:tracef( "response body: %s", resBody )
			if resBody then
				local resJson = JSON:decode( resBody )
				if resHeaders.status == 401 then
					logger:warnf( "GoogleVisionAPI: authorization failure, possibly expired token; try re-auth" )
					attempts = attempts + 1
					local auth = GoogleVisionAPI.authenticate()
					if auth.status then
						-- retry with new token
					else
						-- re-auth failed, bail
						return auth
					end
				elseif resHeaders.status == 200 then
					local results = { status = true, elapsed = elapsed }
					for _, res in ipairs( resJson.responses ) do
						if res.labelAnnotations then
							results.labels = res.labelAnnotations
						else
							results.labels = { }
						end
						if res.landmarkAnnotations then
							results.landmarks = res.landmarkAnnotations
						else
							results.landmarks = { }
						end
					end
					return results
				else
					logger:errorf( "GoogleVisionAPI: analyze API failed: %s", inspect( resJson ) )
					return { status = false, message = resJson.error.message }
				end
			else
				logger:errorf( "GoogleVisionAPI: network error: %s(%d): %s", resHeaders.error.errorCode, resHeaders.error.nativeCode, resHeaders.error.name )
				return { status = false, message = resHeaders.error.name }
			end
		else
			logger:warnf( "GoogleVisionAPI: authorization token missing; try re-auth" )
			attempts = attempts + 1
			local auth = GoogleVisionAPI.authenticate()
			if auth.status then
				-- retry with new token
			else
				-- re-auth failed, bail
				return auth
			end
		end
	end
	logger:errorf( "GoogleVisionAPI: exceeded number of retries" )
	return { status = false, message = "Exceeded number of retries" }
end
