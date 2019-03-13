# NpcInteract
FFXI Windower addon for multiboxers to reduce tedious switching. Make your alts copy your main's NPC interactions!

## Installation
After downloading, extract to your Windower addons folder. Make sure the folder is called NpcInteract, rather than NpcInteract-master or NpcInteract-v1.whatever. Your file structure should look like this:

    addons/NpcInteract/NpcInteract.lua

Once the addon is in your Windower addons folder, it won't show up in the Windower launcher. You need to add a line to your scripts/init.txt:

    lua load NpcInteract

## Commands

    //npc mirror -- Will toggle mirroring, causing all other alts to mirror this one.  
    //ffo retry -- Retry the last NPC interaction.  
    //ffo reset -- Try this if alts get frozen when attempting to interact with an NPC.  
