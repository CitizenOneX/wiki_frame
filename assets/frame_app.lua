-- we store the data from the host quickly from the data handler interrupt
-- and wait for the main loop to pick it up for processing/drawing
-- app_data.text is either the text that will be sent to Wikipedia for querying content
--               or the response containing the wiki content (possibly split into query/wiki in future)
local app_data = { text = "" }
-- true while strings should append, false when string is finalized
local building_text = false
-- true when the data handler is signalling to the main loop that the text should be drawn.
-- Main loop sets it back to false when drawn
local draw_text = false

-- Frame to phone flags
BATTERY_LEVEL_FLAG = "\x0c"

-- Phone to Frame flags
NON_FINAL_CHUNK_FLAG = 0x0a
FINAL_CHUNK_FLAG = 0x0b


-- every time byte data arrives just extract the data payload from the message
-- and save to the local app_data table so the main loop can pick it up and print it
-- format of [data] (a multi-line text string) is:
-- first digit will be 0x0a/0x0b non-final/final chunk of long text
-- followed by string bytes out to the mtu
function data_handler(data)
    if string.byte(data, 1) == NON_FINAL_CHUNK_FLAG then
        -- non-final chunk
        if building_text then
            app_data.text = app_data.text .. string.sub(data, 2)
        else
            -- first chunk of new text
            building_text = true
            app_data.text = string.sub(data, 2)
        end
    elseif string.byte(data, 1) == FINAL_CHUNK_FLAG then
        -- final chunk
        if building_text then
            -- final chunk of new text
            app_data.text = app_data.text .. string.sub(data, 2)
        else
            -- first and final chunk of new text
            app_data.text = string.sub(data, 2)
        end
        building_text = false
        draw_text = true
    end
end

-- draw the current text on the display
-- Note: For lower latency for text to first appear, we could draw the wip text as it arrives
-- keeping track of horizontal and vertical offsets to continue drawing subsequent packets
function print_text()
    local i = 0
    for line in app_data.text:gmatch("([^\n]*)\n?") do
        if line ~= "" then
            frame.display.text(line, 1, i * 60 + 1)
            i = i + 1
        end
    end

end

-- Main app loop
function app_loop()
    local last_batt_update = 0
    while true do
        rc, err = pcall(
            function()
                -- only need to print it once when it's ready, it will stay there
                if draw_text then
                    print_text()
                    frame.display.show()
                    draw_text = false
                end

                frame.sleep(0.1)

                -- periodic battery level updates
                local t = frame.time.utc()
                if (last_batt_update == 0 or (t - last_batt_update) > 180) then
                    pcall(frame.bluetooth.send, BATTERY_LEVEL_FLAG .. string.char(math.floor(frame.battery_level())))
                    last_batt_update = t
                end

                -- TODO clear display after an amount of time?
            end
        )
        -- Catch the break signal here and clean up the display
        if rc == false then
            -- send the error back on the stdout stream
            print(err)
            frame.display.text(" ", 1, 1)
            frame.display.show()
            frame.sleep(0.04)
            break
        end
    end
end

-- register the handler as a callback for all data sent from the host
frame.bluetooth.receive_callback(data_handler)

-- run the main app loop
app_loop()