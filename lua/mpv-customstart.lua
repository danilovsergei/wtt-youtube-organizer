local mp = require 'mp'
local os = require('os')

-- seconds amount watched during current session
local watch_time = 0

-- save_watch_time captures how many seconds user watched youtube video
-- and sums it with seconds watched previously and saves to file defined in WATCHED_FILE_NAME env variable
-- such logic is required because youtube video is a stream and for mpv it always starts from zero
--
-- watched previously seconds are coming through WATCHED_SECONDS env variable ,
-- but eventually these are seconds saved in file from WATCHED_FILE_NAME env
local function save_watch_time()
    local path = mp.get_property('path')
    local watched_file = os.getenv("WATCHED_FILE_NAME")
    -- Seconds amount watched during previous session and saved to watched_file
    local saved_watched_seconds = 0
    if os.getenv("WATCHED_SECONDS") ~= nil then
        saved_watched_seconds = tonumber(os.getenv("WATCHED_SECONDS"))
    end
    local total_watched_seconds = watch_time + saved_watched_seconds
    mp.msg.info("Save watched seconds of "..total_watched_seconds)

    local file = io.open(watched_file, 'w')
    if file then
        file:write(total_watched_seconds)
        file:close()
    end
end

-- update the watch_time every second during playback
mp.observe_property("time-pos", "number", function(_, time)
    if time then
      watch_time = math.floor(time)
    end
end)


mp.register_event('shutdown', save_watch_time)
