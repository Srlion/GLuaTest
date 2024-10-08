local Helpers = {}
local expect = include( "gluatest/expectations/expect.lua" )
local stubMaker = include( "gluatest/stubs/stubMaker.lua" )

------------------
-- Cleanup stuff--
------------------

local makeHookTable = function()
    local trackedHooks = {}
    local hook_Add = function( event, name, func, ... )
        if not trackedHooks[event] then trackedHooks[event] = {} end
        table.insert( trackedHooks[event], name )

        if not isfunction( func ) and func.IsStub then
            local givenStub = func
            func = function( ... )
                givenStub( ... )
            end
        end

        return _G.hook.Add( event, name, func, ... )
    end

    local function cleanup()
        for event, names in pairs( trackedHooks ) do
            for _, name in ipairs( names ) do
                _G.hook.Remove( event, name )
            end
        end
    end

    local newHookTable = setmetatable( {}, {
        __index = function( _, key )
            if key == "Add" then
                return hook_Add
            end

            return rawget( _G.hook, key )
        end,

        __newindex = function( _, key, value )
            rawset( _G.hook, key, value )
        end
    } )

    return newHookTable, cleanup
end

local timerCount = 0
local function makeTimerTable()
    local timerNames = {}

    local timer_Create = function( identifier, delay, reps, func, ... )
        table.insert( timerNames, identifier )

        return timer.Create( identifier, delay, reps, func, ... )
    end

    local timer_Simple = function( delay, func )
        local name = "simple_timer_" .. timerCount
        timerCount = timerCount + 1

        timer_Create( name, delay, 1, func )
    end

    local function cleanup()
        for _, name in ipairs( timerNames ) do
            timer.Remove( name )
        end
    end

    return table.Inherit( { Create = timer_Create, Simple = timer_Simple }, timer ), cleanup
end

local function makeTestLibStubs()
    local testHook, hookCleanup = makeHookTable()
    local testTimer, timerCleanup = makeTimerTable()

    local testEnv = {
        hook = testHook,
        timer = testTimer
    }

    local function cleanup()
        hookCleanup()
        timerCleanup()
    end

    return testEnv, cleanup
end

local function makeTestTools()
    local stub, stubCleanup = stubMaker()

    local tools = {
        stub = stub,
        expect = expect,
    }

    local function cleanup()
        stubCleanup()
    end

    return tools, cleanup
end

local function makeTestEnv()
    local testEnv, envCleanup = makeTestLibStubs()
    local testTools, toolsCleanup = makeTestTools()

    local function cleanup()
        envCleanup()
        toolsCleanup()
    end

    local env = setmetatable(
        testTools,
        {
            __index = function( _, idx )
                return testEnv[idx] or _G[idx]
            end,
        }
    )

    hook.Run( "GLuaTest_EnvCreated", env )

    return env, cleanup
end

local function getLocals( thread, level )
    local locals = {}
    local i = 1

    while true do
        local name, value = debug.getlocal( thread, level, i )
        if name == nil then break end
        if name ~= "(*temporary)" then
            table.insert( locals, { name, value == nil and "nil" or value } )
        end
        i = i + 1
    end

    return locals
end

-- OLD: FIXME: There has to be a better way to do this
-- NEW: Fixed by srlion :)
local function findStackInfo( thread, caseFunc, reason )
    -- Step through the stack to find the first non-C function call. If no stack is found for the called function, it will point to case function. This case will only happen
    -- when the function is tail called, and the error is thrown from the tail called function.
    local lastInfoLevel, lastInfo
    for level = 0, 20 do
        local info = debug.getinfo( thread, level, "nSl" )
        if info and info.short_src ~= "[C]" and not string.match( info.short_src, "/lua/gluatest/" ) then
            lastInfoLevel, lastInfo = level, info
            break
        end
    end

    local locals
    if not lastInfoLevel then
        ErrorNoHalt(
            "Failed to get a stack, probably returning a function that errored! " ..
            "For example, 'return error('!')'\n"
        )
        lastInfo = debug.getinfo( caseFunc, "nSl" )
        lastInfo.currentline = lastInfo.linedefined -- currentline will be -1, so we will point it to the line where the function was defined

        locals = {} -- We can't get locals from a function that has tail call returns
    else
        -- We got info about the error, but if the error was thrown from calling a nil value 'thisdoesntexist()', we can't get the currentline (executing line) as it was a nil value!
        -- Thankfully, the error message will contain the line number, so we can extract it from there.
        if lastInfo.currentline == -1 then
            local line = string.match( reason, ":(%d+):" )
            if line then
                lastInfo.currentline = tonumber( line )
            end
        end

        locals = getLocals( thread, lastInfoLevel )
    end

    return lastInfo, locals
end

function Helpers.FailCallback( thread, caseFunc, reason )
    if reason == "" then
        ErrorNoHaltWithStack( "Received empty error reason in failCallback- ignoring " )
        return
    end

    -- root/file/name.lua:420: Expectation Failed: Failure reason
    -- root/file/name.lua:420: attempt to index nil value 'blah'
    local reasonSpl = string.Split( reason, ": " )

    if reasonSpl[2] == "Expectation Failed" then
        table.remove( reasonSpl, 2 )
    else
        table.insert( reasonSpl, 2, "Unhandled" )
    end

    local cleanReason = table.concat( reasonSpl, ": ", 2, #reasonSpl )

    local info, locals = findStackInfo( thread, caseFunc, reason )

    return {
        reason = cleanReason,
        sourceFile = info.short_src,
        lineNumber = info.currentline,
        locals = locals,
        thread = thread
    }
end

function Helpers.MakeAsyncEnv( done, fail, onFailedExpectation )
    -- TODO: How can we make Stubs safer in Async environments?
    local stub, stubCleanup = stubMaker()
    local testEnv, envCleanup = makeTestLibStubs()

    local function cleanup()
        envCleanup()
        stubCleanup()
    end

    local env = setmetatable(
        {
            -- We manually catch expectation errors here in case
            -- they're called in an async function
            expect = function( subject )
                local built = expect( subject )
                local expected = built.to.expected
                local recordedFailure = false

                -- Wrap the error-throwing function
                -- and handle the error with the correct context
                built.to.expected = function( ... )
                    if recordedFailure then return end

                    local _, errInfo = Helpers.SafeRunFunction( expected, ... )
                    onFailedExpectation( errInfo )

                    recordedFailure = true
                end

                return built
            end,

            done = done,
            fail = fail,
            stub = stub,
        },
        {
            __index = function( _, idx )
                return testEnv[idx] or _G[idx]
            end
        }
    )

    hook.Run( "GLuaTest_AsyncEnvCreated", env )

    return env, cleanup
end

function Helpers.SafeRunWithEnv( defaultEnv, before, func, state )
    local testEnv, cleanup = makeTestEnv()
    local ranExpect = false

    local ogExpect = testEnv.expect
    testEnv.expect = function( ... )
        ranExpect = true
        testEnv.expect = ogExpect
        return ogExpect( ... )
    end

    setfenv( before, testEnv )
    before( state )
    setfenv( before, defaultEnv )

    setfenv( func, testEnv )
    local success, errInfo = Helpers.SafeRunFunction( func, state )
    setfenv( func, defaultEnv )

    cleanup()

    -- If it succeeded but never ran `expect`, it's an empty test
    if success and not ranExpect then
        return nil, nil
    end

    return success, errInfo
end

function Helpers.SafeRunFunction( func, ... )
    local co = coroutine.create( func )
    local success, err = coroutine.resume( co, ... )

    local errInfo
    if not success then
        errInfo = Helpers.FailCallback( co, func, err )
    end

    return success, errInfo
end

function Helpers.CreateCaseState( testGroupState )
    return setmetatable( {}, {
        __index = function( self, idx )
            if testGroupState[idx] ~= nil then
                return testGroupState[idx]
            end

            if rawget( self, idx ) ~= nil then
                return rawget( self, idx )
            end
        end
    } )
end

return Helpers
