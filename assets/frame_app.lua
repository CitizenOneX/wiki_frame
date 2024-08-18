-- we store the data from the host quickly from the data handler interrupt
-- and wait for the main loop to pick it up for processing/drawing
-- app_data.text is either the text that will be sent to Wikipedia for querying content
--               or the response containing the wiki content (possibly split into query/wiki in future)
-- app_data.image_data_table is the thumbnail image associated with the Wikipedia page (if present) as rows of bytes from each message
local app_data = { text = '', image_width = 0, image_height = 0, image_bpp = 0, image_num_colors = 0, image_palette = '', image_bytes = 0, received_bytes = 0, image_data_table = {} }
-- true while strings should append, false when string is finalized
local building_text = false
-- true when the data handler is signalling to the main loop that the text/image should be drawn.
-- Main loop sets it back to false when drawn
local draw_text = false
local draw_image = false

-- Frame to phone flags
BATTERY_LEVEL_FLAG = "\x0c"

-- Phone to Frame flags
NON_FINAL_CHUNK_FLAG = 0x0a
FINAL_CHUNK_FLAG = 0x0b
IMAGE_CHUNK_FLAG = 0x0d


-- every time byte data arrives just extract the data payload from the message
-- and save to the local app_data table so the main loop can pick it up and print it
-- format of [data] (a multi-line text string) is:
-- first digit will be 0x0a/0x0b non-final/final chunk of long text (or 0x0d for an image)
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
    elseif string.byte(data, 1) == IMAGE_CHUNK_FLAG then
        if app_data.image_data_table[1] == nil then
            -- new image; read the header
            -- width(Uint16), height(Uint16), bpp(Uint8), numColors(Uint8), palette (Uint8 r, Uint8 g, Uint8 b)*numColors, data (length width x height x bpp/8)
            app_data.image_width = string.byte(data, 2) << 8 | string.byte(data, 3)
            app_data.image_height = string.byte(data, 4) << 8 | string.byte(data, 5)
            app_data.image_bpp = string.byte(data, 6)
            app_data.image_num_colors = string.byte(data, 7)
            app_data.image_palette = string.sub(data, 8, 8 + 3*i - 1)
            app_data.image_bytes = app_data.image_width * app_data.image_height * app_data.image_bpp / 8

            -- read the remaining bytes and update received_bytes
            table.insert(app_data.image_data_table, string.sub(data, 8 + 3*i))
            received_bytes = data.length - 9 - 3*i
        else
            -- copy the bytes to the image_data_table and update received_bytes
            table.insert(app_data.image_data_table, string.sub(data, 2))
            received_bytes = received_bytes + data.length - 1
        end

        if app_data.received_bytes == app_data.image_bytes then
            draw_image = true
        end
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

-- draw the image on the display
function print_image()
    frame.display.bitmap(400, 0, app_data.image_width, 2, 1, string.rep("\xFF", app_data.image_width / 8 * 16)) -- TODO table.concat(app_data.image_data_table))
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

                if draw_image then
                    print_image()
                    frame.display.show()
                    draw_image = false
                    for k, v in pairs(app_data.image_data_table) do app_data.image_data_table[k] = nil end
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