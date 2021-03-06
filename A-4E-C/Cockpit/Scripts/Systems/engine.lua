local Engine     = GetSelf()
local dev = Engine
dofile(LockOn_Options.common_script_path.."devices_defs.lua")
dofile(LockOn_Options.script_path.."command_defs.lua")
dofile(LockOn_Options.script_path.."Systems/electric_system_api.lua")
dofile(LockOn_Options.script_path.."utils.lua")

function debug_print(x)
    --print_message_to_user(x)
end

local update_rate = 0.05
make_default_activity(update_rate)

local sensor_data = get_base_data()


sensor_data.mod_fuel_flow = function()
	local org_fuel_flow = sensor_data.getEngineLeftFuelConsumption() 
	if org_fuel_flow > 0.9743 then org_fuel_flow = 0.9743 end
	return org_fuel_flow
end

local iCommandEnginesStart=309
local iCommandEnginesStop=310

local pressure_ratio = get_param_handle("PRESSURE_RATIO")
local oil_pressure = get_param_handle("OIL_PRESSURE")
local egt_c = get_param_handle("EGT_C")
local engine_heat_stress = get_param_handle("ENGINE_HEAT_STRESS")

local throttle_position = get_param_handle("THROTTLE_POSITION")
local throttle_position_wma = WMA(0.15, 0)
local iCommandPlaneThrustCommon = 2004

local ENGINE_OFF = 0
local ENGINE_IGN = 1
local ENGINE_STARTING = 2
local ENGINE_RUNNING = 3
local engine_state = ENGINE_OFF

local THROTTLE_OFF = 0
local THROTTLE_IGN = 1
local THROTTLE_ADJUST = 2
local throttle_state = THROTTLE_ADJUST

------------------------------------------------
----------------  CONSTANTS  -------------------
------------------------------------------------

------------------------------------------------
-----------  AIRCRAFT DEFINITION  --------------
------------------------------------------------

Engine:listen_command(device_commands.push_starter_switch)
Engine:listen_command(Keys.Engine_Start)
Engine:listen_command(Keys.Engine_Stop)
--Engine:listen_command(device_commands.throttle_axis)

function post_initialize()
	
	local dev = GetSelf()
    dev:performClickableAction(device_commands.push_starter_switch,0,false)
    local throttle_clickable_ref = get_clickable_element_reference("PNT_80")
    local sensor_data = get_base_data()
    local throttle = sensor_data.getThrottleLeftPosition()

    local birth = LockOn_Options.init_conditions.birth_place
    if birth=="GROUND_HOT" then
        engine_state = ENGINE_RUNNING
        throttle_state = THROTTLE_ADJUST
        throttle_clickable_ref:hide(throttle>0.01)
        dev:performClickableAction(device_commands.throttle_click,1,false)
    elseif birth=="AIR_HOT" then
        engine_state = ENGINE_RUNNING
        throttle_state = THROTTLE_ADJUST
        dev:performClickableAction(device_commands.throttle_click,1,false)
        throttle_clickable_ref:hide(throttle>0.01)
    elseif birth=="GROUND_COLD" then
        engine_state = ENGINE_OFF
        throttle_state = THROTTLE_OFF
        throttle_clickable_ref:hide(false)
        throttle_position:set(-1)
        dev:performClickableAction(device_commands.throttle_click,-1,false)
    end
end

--[[
pilot controlled ground start sequence:
1. connect external power and huffer (request ground power ON from ground crew)
2. Throttle to OFF position
3. Press starter switch (dispatch iCommandEnginesStart), this is supposed to let in external compressor air to drive engine
4. When RPM at 5%, move throttle to ignition (otherwise if by say 14% without ignition, dispatch iCommandEnginesStop [or to be fancy, try to control RPM to remain around this level by dispatching repeated start/stop])
5. When RPM at 15%, move throttle to idle (otherwise if by say 22% without idle position, dispatch iCommandEnginesStop [or to be fancy, try to control RPM to to pre-ignition level by dispatching repeated start/stop])
6. When RPM gets to 55%, request ground power OFF
--]]

local start_button_popup_timer = 0
function SetCommand(command,value)
	local rpm = sensor_data.getEngineLeftRPM()
    local throttle = sensor_data.getThrottleLeftPosition()

    if command==device_commands.push_starter_switch then
        if value==1 then
            if (engine_state==ENGINE_OFF) and rpm<5 and get_elec_external_power() then -- initiate ground start procedure
                dispatch_action(nil,iCommandEnginesStart)
            elseif (engine_state==ENGINE_OFF) and rpm<50 and rpm>10 and get_elec_primary_ac_ok() and get_elec_primary_dc_ok() and throttle_state==THROTTLE_IGN then -- initiate air start
                engine_state = ENGINE_STARTING
                dispatch_action(nil,iCommandEnginesStart)
            else
                start_button_popup_timer = 0.3
            end
        end
        if value==0 then
            if (engine_state==ENGINE_IGN or engine_state==ENGINE_STARTING) and rpm<50 and get_elec_external_power() then -- abort ground start procedure
                engine_state=ENGINE_OFF
                dispatch_action(nil,iCommandEnginesStop)
            end
        end
    elseif command==Keys.Engine_Start then
        Engine:performClickableAction(device_commands.push_starter_switch,1,false)
    elseif command==Keys.Engine_Stop then
        Engine:performClickableAction(device_commands.push_starter_switch,0,false)
        debug_print("engine has been turned off")
        throttle_state = THROTTLE_OFF
        engine_state = ENGINE_OFF
        dispatch_action(nil,iCommandEnginesStop)
        dev:performClickableAction(device_commands.throttle_click,-1,false)
--    elseif command==device_commands.throttle_axis then
--        -- value is -1 for throttle full forwards, 1 for throttle full back
--        --local throt = (2-(value+1))/2.0
--        local throt = value
--        --print_message_to_user("throt"..string.format("%.2f",throt))
--        dispatch_action(nil, iCommandPlaneThrustCommon, throt)
    elseif command==device_commands.throttle_click then
        if value==0 and throttle_state==THROTTLE_ADJUST and throttle<=0.01 then
            -- click to IGN from adjust
            throttle_state = THROTTLE_IGN
        elseif value==0 and throttle_state==THROTTLE_OFF then
            -- click to IGN from OFF
            throttle_state = THROTTLE_IGN
        elseif value==-1 and throttle_state==THROTTLE_IGN then
            -- click to OFF from IGN
            throttle_state = THROTTLE_OFF
            if rpm>=55 and engine_state == ENGINE_RUNNING then
                debug_print("engine has been turned off")
                dispatch_action(nil,iCommandEnginesStop)
                engine_state = ENGINE_OFF
            end
        elseif value==1 and throttle_state==THROTTLE_IGN then
            -- click to ADJUST from IGN
            throttle_state = THROTTLE_ADJUST
        end
    else
        print_message_to_user("engine unknown cmd: "..command.."="..tostring(value))
    end
end

local egt_c_val=WMA(0.02)
-- update EGT as a function of calculated thrust
function update_egt()
    local mach = sensor_data.getMachNumber()
    local alt = sensor_data.getBarometricAltitude()
    --local thrust = sensor_data.getEngineLeftFuelConsumption()*2.20462*3600
	local thrust = sensor_data.mod_fuel_flow()*2.20462*3600

    -- SFC is 20% higher at M0.8 compared to M0.0 at 10,000'
    -- SFC reduces by ~3.7% per 3300m delta from 10,000' at M0.8
    local sfc_mod_mach
    if mach <= 0.8 then
        sfc_mod_mach = ((mach-0.8) * .2) + 1
    else
        sfc_mod_mach = 1.2
    end

    local alt_delta = math.abs(alt - 3300)
    local sfc_mod_alt = 1.0 - (0.037*(alt_delta/3300))
    thrust = thrust * sfc_mod_mach * sfc_mod_alt
    --print_message_to_user("thrust: "..thrust)


    if thrust > 8400 then
        output_egt = (thrust-8400)*0.0633 + 593
    elseif thrust > 6800 then
        output_egt = (thrust-6800)*0.0481 + 516
    elseif thrust > 0 then
        output_egt = thrust*0.0274 + 325
    else
        output_egt = 0
    end

    --print_message_to_user("EGT_o: "..output_egt)

    egt_c:set(egt_c_val:get_WMA(output_egt))
end



local rpm_main = get_param_handle("RPM")
local rpm_deci = get_param_handle("RPM_DECI")

function update_rpm()
    -- idle at 55% internal, max 103%
    -- draw .534 at 55%, draw 1.0 at 100%
    local rpm=sensor_data.getEngineLeftRPM()

    if rpm < 55 then
        rpm_main:set(rpm/1.03)
    else
        rpm = rpm - 55
        rpm = (rpm * 1.0667) + 55 -- scale 55 to 100 input to 102.9% reporting maximum
        rpm_main:set(rpm)
    end

    rpm=rpm/10.0
    rpm=rpm-math.floor(rpm)
    rpm_deci:set(rpm)
end



local oil_pressure_psi=WMA(0.15,0)
--[[
NATOPS:
Engine oil pressure is shown on the oil pressure indicator
(figures FO-1 and FO- 2) on the instrument panel.
Normal oil pressure is 40 to 50 psi. Minimum oil
pressure for ground IDLE is 35psi.
NOTE:
- Maneuvers producing acceleration near zero
"g" may cause a temporary loss of oil pressure.
Absence of oil pressure for a maximum
of 10 seconds is permissible.
- Oil pressure indications are available on
emergency generator.

OIL PRESSURE VARIATION
The oil pressure indication at IDLE RPM should be
normal (40 to 50 psi); however, a minimum of 35 psi
for ground operation is acceptable. If the indication
is less than 35 psi at 60 percent rpm, shut down the
engine to determine the reason for the lack of, or
low, oil pressure.
- Even though certain maneuvers normally
cause a momentary loss of oil pressure,
maximum operating time with an oil pressure
indicating less than 40 psi in flight is
1 minute. If oil pressure is not recovered
in 1 minute, the flight should be terminated
as soon as practicable.
- Maneuvers producing acceleration near zero
g may cause complete loss of oil pressure
temporarily. Absence of oil pressure for
a maximum of 10 seconds is permissible.
- If the oil pressure indicator reads high (over
50 psi), the throttle setting should be made as
soon as possible, and the cause investigated.
NOTE:
During starting and initial runup, the maximum
allowable oil pressure is 50 psi.
--]]
function update_oil_pressure()
    local rpm = sensor_data.getEngineLeftRPM()
    
    local oil_pressure_nominal
    if get_elec_26V_ac_ok() then -- will have power on main and emergency generator
        if rpm < 55 then
            oil_pressure_target=35
        else
            -- oil pressure 40-45 based on RPM
            oil_pressure_target = 5 * (rpm-55)/45 + 40
        end

        local stress = engine_heat_stress:get()
        oil_pressure_target = oil_pressure_target + stress * (40/100) -- up to 40psi oil pressure due to heat buildup
    else
        oil_pressure_target=0
    end

    oil_pressure:set(oil_pressure_psi:get_WMA(oil_pressure_target))
end


-- pressure ratio is essentially thrust
-- MIL thrust (9310 lbf) is a PR of 2.83 = 4137N
-- to figure out current thrust, we need to divide fuel consumption by SFC to get force
local pressure_ratio_val=WMA(0.15,0)

function update_pressure_ratio()
    local prt = 1.2

    if get_elec_fwd_mon_ac_ok() then -- no power on emergency generator
        --prt = (sensor_data.getEngineLeftFuelConsumption()*3600/0.86) / 4137
		prt = (sensor_data.mod_fuel_flow()*3600/0.86) / 4137
		
		
        --print_message_to_user("pct max thrust: "..prt)
        prt = (prt*1.83) + 1
        --print_message_to_user("pr: "..prt)
    end

    pressure_ratio:set(pressure_ratio_val:get_WMA(prt))
end

local life_s_accum = 0
function accumulate_temp()
    local temp = egt_c:get()

    -- 30 min max @ 649 C (dc = 55.6 C)     -- accumulate 1 degree*sec up to 650
    -- 8 minute max @ 677 C (dC = 83.35 C)  -- accumulate 2 degree*sec beyond 650

    -- from excel:  lifetime y = 28563e^(-0.049 x) where x is degrees C above 593.5
    
    -- accumulate 1/lifeseconds per second while hot

    if temp > 593.5 then
        life_s_accum = life_s_accum + (100 / (28563 * math.exp(-0.049 * (temp-593.5))))
    else
        life_s_accum = life_s_accum + (temp-593.5)/1000
    end

    if life_s_accum <= 0 then
        life_s_accum = 0
    end

    engine_heat_stress:set(life_s_accum)
end

local prev_rpm=0
local prev_throttle_pos=0
local once_per_sec = 1/update_rate
function update()
	local rpm = sensor_data.getEngineLeftRPM()
    local throttle = sensor_data.getThrottleLeftPosition()
    local gear = get_aircraft_draw_argument_value(0) -- nose gear
  
    update_rpm()
    update_oil_pressure()
    update_pressure_ratio()
    update_egt()

    once_per_sec = once_per_sec - 1
    if once_per_sec <= 0 then
        accumulate_temp()

        once_per_sec = 1/update_rate
    end



	if (engine_state==ENGINE_STARTING) and rpm > 50 then
        Engine:performClickableAction(device_commands.push_starter_switch,0,false) -- pop up start button
    end
    if start_button_popup_timer > 0 then
        start_button_popup_timer = start_button_popup_timer - update_rate
        if start_button_popup_timer <= 0 then
            start_button_popup_timer = 0
            Engine:performClickableAction(device_commands.push_starter_switch,0,false) -- pop up start button
        end
    end

    if prev_rpm ~= rpm then
        if rpm >= 55 then
            if engine_state == ENGINE_STARTING then
                engine_state = ENGINE_RUNNING
            end
        else
            if rpm>=5 and engine_state == ENGINE_OFF then
                if rpm>14 and get_cockpit_draw_argument_value(100)>0.99 then
                    debug_print("failed to ignite engine")
                    dispatch_action(nil,iCommandEnginesStop)
                    Engine:performClickableAction(device_commands.push_starter_switch,0,false) -- pop up start button
                elseif throttle_state==THROTTLE_IGN and get_cockpit_draw_argument_value(100)>0.99 then
                    engine_state = ENGINE_IGN
                    debug_print("igniting engine")
                end
            end
            if rpm>=22 and (engine_state == ENGINE_IGN or throttle_state ~= THROTTLE_ADJUST) and get_cockpit_draw_argument_value(100)>0.99 then
                debug_print("failed to IDLE throttle")
                Engine:performClickableAction(device_commands.push_starter_switch,0,false) -- pop up start button
            end
            if rpm>=15 and engine_state == ENGINE_IGN and get_cockpit_draw_argument_value(100)>0.99 then
                if throttle_state==THROTTLE_ADJUST then
                    debug_print("starting engine")
                    engine_state = ENGINE_STARTING
                end
            end
            if (engine_state == ENGINE_IGN or engine_state == ENGINE_STARTING) and throttle_state==THROTTLE_OFF and get_cockpit_draw_argument_value(100)>0.99 then
                debug_print("abort engine start")
                Engine:performClickableAction(device_commands.push_starter_switch,0,false) -- pop up start button
            end
        end
        if rpm<54 and engine_state == ENGINE_RUNNING then
            debug_print("engine has gone off")
            engine_state = ENGINE_OFF
        end
        if rpm>=55 and engine_state == ENGINE_RUNNING and throttle_state==THROTTLE_OFF then
            debug_print("engine has been turned off")
            dispatch_action(nil,iCommandEnginesStop)
            engine_state = ENGINE_OFF
        end

        prev_rpm = rpm
    end

    if throttle_state == THROTTLE_OFF then
        throttle = -1
    elseif throttle_state == THROTTLE_IGN then
        throttle = -0.2
    elseif throttle_state == THROTTLE_ADJUST then
        local throttle_clickable_ref = get_clickable_element_reference("PNT_80")
        throttle_clickable_ref:hide(throttle>0.01)
    end

    local throttle_pos = throttle_position_wma:get_WMA(throttle)
    if prev_throttle_pos ~= throttle_pos then
        if throttle <= 0.01 then
            local throttle_clickable_ref = get_clickable_element_reference("PNT_80")
            throttle_clickable_ref:update() -- ensure it is clickable at the correct position
        end
        prev_throttle_pos = throttle_pos
    end
    throttle_position:set(throttle_pos)
end


need_to_be_closed = false -- close lua state after initialization
