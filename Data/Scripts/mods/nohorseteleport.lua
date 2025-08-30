NoHorseTeleportStarter = {}

function NoHorseTeleportStarter:sceneInitListener(actionName, eventName, argTable)
    local demoEntityParams = {}
    demoEntityParams.class = "NoHorseTeleport"
    demoEntityParams.name = "NoHorseTeleport_Instance"
    System.SpawnEntity(demoEntityParams)
end

-- initialize the mod after the player-scene has started
UIAction.RegisterEventSystemListener(NoHorseTeleportStarter, "System", "OnGameplayStarted", "sceneInitListener")
