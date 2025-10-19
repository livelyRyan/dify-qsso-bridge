-- Check if the request path is /qsso_backcall or /qsso_backcall/
if ngx.var.request_uri == "/qsso_backcall" or ngx.var.request_uri == "/qsso_backcall/" then

    -- Generate trace_id for request tracking
    local trace_id = tostring(ngx.now())

    -- Get configuration from environment variables, use default values if not set
    local dify_token_by_qsso_api_base_url = os.getenv("DIFY_TOKEN_BY_QSSO_API_BASE_URL")
    local dify_home_page_base_url = os.getenv("DIFY_HOME_PAGE_BASE_URL")
    local custom_error_message_prefix = "Login error, please contact administrator. Trace ID: " .. trace_id .. ", Error: "

    ngx.log(ngx.WARN, "redirect_script: [TRACE_ID: ", trace_id, "] dify_token_by_qsso_api_base_url: ", dify_token_by_qsso_api_base_url)
    ngx.log(ngx.WARN, "redirect_script: [TRACE_ID: ", trace_id, "] dify_home_page_base_url: ", dify_home_page_base_url)
    ngx.log(ngx.WARN, "redirect_script: [TRACE_ID: ", trace_id, "] Processing request for ", ngx.var.request_uri)

    -- Load required libraries for HTTP requests and JSON parsing
    local http = require "resty.http"
    local cjson = require "cjson"

    -- Check if libraries loaded successfully
    if not http or not cjson then
        local missing_libs = {}
        if not http then table.insert(missing_libs, "resty.http") end
        if not cjson then table.insert(missing_libs, "cjson") end
        ngx.log(ngx.ERR, "redirect_script: [TRACE_ID: ", trace_id, "] Required library/libraries not found: ", table.concat(missing_libs, ", "))
        ngx.header.content_type = 'text/plain; charset=utf-8'
        ngx.status = ngx.HTTP_INTERNAL_SERVER_ERROR
        ngx.say(custom_error_message_prefix)
        return
    end

    -- Read POST parameters from request body
    ngx.req.read_body()
    local post_args, err_post = ngx.req.get_post_args()
    local initial_token_str = nil

    -- Check if POST parameters were read successfully
    if err_post then
        ngx.log(ngx.ERR, "redirect_script: [TRACE_ID: ", trace_id, "] Error getting POST arguments: ", err_post)
        ngx.header.content_type = 'text/plain; charset=utf-8'
        ngx.status = ngx.HTTP_BAD_REQUEST
        ngx.say(custom_error_message_prefix)
        return
    end

    -- Check if 'token' parameter exists in POST data
    if post_args and post_args.token then
        if type(post_args.token) == "table" then
            initial_token_str = tostring(post_args.token[1])
        else
            initial_token_str = tostring(post_args.token)
        end
        ngx.log(ngx.WARN, "redirect_script: [TRACE_ID: ", trace_id, "] Intercepted initial token: ", initial_token_str)
    else
        local msg = "'token' not found in FormData or No FormData (POST arguments) found."
        if not post_args then
            msg = "No FormData (POST arguments) found in the request."
        end
        ngx.log(ngx.WARN, "redirect_script: [TRACE_ID: ", trace_id, "] ", msg)
        ngx.header.content_type = 'text/plain; charset=utf-8'
        ngx.status = ngx.HTTP_BAD_REQUEST
        ngx.say(custom_error_message_prefix)
        return
    end

    -- Validate QSSO token and exchange it for Dify tokens
    if initial_token_str then
        local httpc = http.new()
        local encoded_initial_token = ngx.escape_uri(initial_token_str)

        -- Build request URL to get Dify tokens
        local target_url = dify_token_by_qsso_api_base_url .. "?trace_id=" .. trace_id .. "&token=" .. encoded_initial_token
      
        ngx.log(ngx.WARN, "redirect_script: [TRACE_ID: ", trace_id, "] Requesting Dify token API: ", target_url)

        -- Send HTTP request to Dify management service
        local res, err_http = httpc:request_uri(target_url, {
            method = "GET",
            timeout = 10000, 
            ssl_verify = false
        })

        -- Check if HTTP request was successful
        if not res then
            ngx.log(ngx.ERR, "redirect_script: [TRACE_ID: ", trace_id, "] Failed to request Dify token API '", target_url, "'. Error: ", err_http)
            ngx.header.content_type = 'text/plain; charset=utf-8'
            ngx.status = ngx.HTTP_INTERNAL_SERVER_ERROR
            ngx.say(custom_error_message_prefix)
            return
        end

        ngx.log(ngx.WARN, "redirect_script: [TRACE_ID: ", trace_id, "] Dify token API responded with status: ", res.status)
        httpc:set_keepalive() 

        -- Check HTTP response status code
        if res.status == ngx.HTTP_OK then
            local data, err_json = cjson.decode(res.body)
            if err_json then
                ngx.log(ngx.ERR, "redirect_script: [TRACE_ID: ", trace_id, "] Failed to decode JSON response from Dify token API. Error: ", err_json, ". Body: ", res.body)
                ngx.header.content_type = 'text/plain; charset=utf-8'
                ngx.status = ngx.HTTP_INTERNAL_SERVER_ERROR 
                ngx.say(custom_error_message_prefix)
                return
            end

            -- Check if response contains access_token and refresh_token
            if data and data.access_token and data.refresh_token then
                local access_token = data.access_token
                local refresh_token = data.refresh_token
                ngx.log(ngx.WARN, "redirect_script: [TRACE_ID: ", trace_id, "] Successfully retrieved access_token and refresh_token. Redirecting...")
                
                -- Build redirect URL to Dify homepage with tokens
                local redirect_url_with_tokens = dify_home_page_base_url ..
                                                    "?access_token=" .. access_token ..
                                                    "&refresh_token=" .. refresh_token
                return ngx.redirect(redirect_url_with_tokens)
            else
                ngx.log(ngx.WARN, "redirect_script: [TRACE_ID: ", trace_id, "] access_token or refresh_token not found in Dify token API response. Response: ", res.body)
                ngx.header.content_type = 'text/plain; charset=utf-8'
                ngx.status = ngx.HTTP_BAD_REQUEST
                ngx.say(custom_error_message_prefix)
                return
            end
        else
            ngx.log(ngx.WARN, "redirect_script: [TRACE_ID: ", trace_id, "] Dify token API responded with status ", res.status, ". Body: ", res.body)
            ngx.header.content_type = 'text/plain; charset=utf-8'
            ngx.status = res.status 
            ngx.say(custom_error_message_prefix)
            return
        end
    else
        ngx.log(ngx.ERR, "redirect_script: [TRACE_ID: ", trace_id, "] Unexpected state, initial_token_str is nil after checks.")
        ngx.header.content_type = 'text/plain; charset=utf-8'
        ngx.status = ngx.HTTP_INTERNAL_SERVER_ERROR
        ngx.say(custom_error_message_prefix)
        return
    end
end
