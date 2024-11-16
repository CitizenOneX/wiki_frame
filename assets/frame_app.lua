local data = require('data.min')
local battery = require('battery.min')
local code = require('code.min')
local image_sprite_block = require('image_sprite_block.min')
local plain_text = require('plain_text.min')

-- Phone to Frame flags
TEXT_FLAG = 0x0a
IMAGE_SPRITE_BLOCK = 0x0d
TAP_SUBS_MSG = 0x10

-- register the message parsers so they are automatically called when matching data comes in
data.parsers[TEXT_FLAG] = plain_text.parse_plain_text
data.parsers[IMAGE_SPRITE_BLOCK] = image_sprite_block.parse_image_sprite_block
data.parsers[TAP_SUBS_MSG] = code.parse_code

-- Frame to Phone flags
TAP_MSG = 0x09

function handle_tap()
	pcall(frame.bluetooth.send, string.char(TAP_MSG))
end

-- draw the current text on the display
function print_text()
    local i = 0
    for line in data.app_data[TEXT_FLAG].string:gmatch("([^\n]*)\n?") do
        if line ~= "" then
            frame.display.text(line, 1, i * 60 + 1)
            i = i + 1
        end
    end

end


-- Main app loop
function app_loop()
	-- clear the display
	frame.display.text(" ", 1, 1)
	frame.display.show()
    local last_batt_update = 0
    while true do
        rc, err = pcall(
            function()
                -- process any raw items, if ready (parse into image or text, then clear raw)
                local items_ready = data.process_raw_items()

                -- TODO tune sleep durations to optimise for data handler and processing
                frame.sleep(0.005)

                -- only need to print it once when it's ready, it will stay there
                -- but if we print either, then we need to print both because a draw call and show
                -- will flip the buffer away from the already-drawn text/image
                if items_ready > 0 then
                    if (data.app_data[TEXT_FLAG] ~= nil and data.app_data[TEXT_FLAG].string ~= nil) then
                        print_text()
                    end

                    if (data.app_data[IMAGE_SPRITE_BLOCK] ~= nil) then
                        -- show the image sprite block
                        local isb = data.app_data[IMAGE_SPRITE_BLOCK]

                        -- it can be that we haven't got any sprites yet, so only proceed if we have a sprite
                        if isb.current_sprite_index > 0 then
                            -- either we have all the sprites, or we want to do progressive/incremental rendering
                            if isb.progressive_render or (isb.active_sprites == isb.total_sprites) then

                                for index = 1, isb.active_sprites do
                                    local spr = isb.sprites[index]
                                    local y_offset = isb.sprite_line_height * (index - 1)

                                    -- set the palette the first time, all the sprites should have the same palette
                                    if index == 1 then
                                        image_sprite_block.set_palette(spr.num_colors, spr.palette_data)
                                    end

                                    frame.display.bitmap(401, y_offset + 1, spr.width, 2^spr.bpp, 0, spr.pixel_data)
                                end

                                frame.display.show()
                            end
                        end
                    end

                    if (data.app_data[TAP_SUBS_MSG] ~= nil) then

                        if data.app_data[TAP_SUBS_MSG].value == 1 then
                            -- start subscription to tap events
                            frame.imu.tap_callback(handle_tap)
                        else
                            -- cancel subscription to tap events
                            frame.imu.tap_callback(nil)
                        end

                        data.app_data[TAP_SUBS_MSG] = nil
                    end


                    frame.display.show()
                end

                -- TODO tune sleep durations to optimise for data handler and processing
                frame.sleep(0.005)

                -- periodic battery level updates
                last_batt_update = battery.send_batt_if_elapsed(last_batt_update, 180)
                frame.sleep(0.1)

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

-- run the main app loop
app_loop()