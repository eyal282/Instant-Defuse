#include <sourcemod>
#include <sdkhooks>
#include <sdktools>
#include <cstrike>
#include <clientprefs>

new EngineVersion:GameName;

#undef REQUIRE_PLUGIN
#tryinclude <autoexecconfig>
#tryinclude <updater>

#define UPDATE_URL "https://raw.githubusercontent.com/eyal282/Instant-Defuse/master/addons/updatefile.txt"

#define PREFIX "\x09[\x04Insta-Defuse\x09]\x01 "

#define PLUGIN_VERSION "2.0"

new Handle:hcv_NoobMargin = INVALID_HANDLE;
new Handle:hcv_PrefDefault = INVALID_HANDLE;
new Handle:hcv_AutoExplode = INVALID_HANDLE;

new Handle:hcv_mpC4Timer = INVALID_HANDLE;

new Handle:hcv_InfernoDuration = INVALID_HANDLE;
new Handle:hcv_InfernoDistance = INVALID_HANDLE;

new Handle:fw_OnInstantDefusePre = INVALID_HANDLE;
new Handle:fw_OnInstantDefusePost = INVALID_HANDLE;

new Handle:hCookie_Enable = INVALID_HANDLE;

new Float:LastDefuseTimeLeft;

new Handle:hTimer_MolotovThreatEnd = INVALID_HANDLE;

new ForceUseEntity[MAXPLAYERS+1];

public Plugin:myinfo = 
{
	name = "Instant Defuse",
	author = "Eyal282",
	description = "Allows you to instantly defuse the bomb when all T are dead and nothing can stop the defuse.",
	version = PLUGIN_VERSION,
	url = ""
}

public OnPluginStart()
{
	GameName = GetEngineVersion();
	
	#if defined _autoexecconfig_included
	
	AutoExecConfig_SetFile("InstantDefuse");
	
	#endif
	
	HookEvent("bomb_begindefuse", Event_BombBeginDefuse, EventHookMode_Post);
	HookEvent("bomb_defused", Event_BombDefused, EventHookMode_Post);
	
	if(isCSGO())
		HookEvent("molotov_detonate", Event_MolotovDetonate);
		
	HookEvent("hegrenade_detonate", Event_AttemptInstantDefuse, EventHookMode_Post);

	HookEvent("player_death", Event_AttemptInstantDefuse, EventHookMode_PostNoCopy);
	HookEvent("round_start", Event_RoundStart, EventHookMode_PostNoCopy);
	
	SetConVarString(CreateConVar("instant_defuse_version", PLUGIN_VERSION), PLUGIN_VERSION);
	
	hcv_NoobMargin = UC_CreateConVar("instant_defuse_noob_margin", "5.2", "To prevent noobs from instantly running for their lives when instant defuse fails, instant defuse won't activate if defuse may be uncertain to the player", FCVAR_NOTIFY);
	hcv_AutoExplode = UC_CreateConVar("instant_defuse_auto_explode", "0", "Set to 1 to make defuses with no chance to happen explode the bomb instantly. Noob margin must be set to 0.0", FCVAR_NOTIFY);
	hcv_PrefDefault = UC_CreateConVar("instant_defuse_pref_default", "1", "If 1, new players will have instant defuse preference enabled by default");
	
	if(isCSGO())
	{
		hcv_InfernoDuration = UC_CreateConVar("instant_defuse_inferno_duration", "7.0", "If Valve ever changed the duration of molotov, this cvar should change with it");
		hcv_InfernoDistance = UC_CreateConVar("instant_defuse_inferno_distance", "225.0", "If Valve ever changed the maximum distance spread of molotov, this cvar should change with it");
	}
	
	hcv_mpC4Timer = FindConVar("mp_c4timer");
	
	fw_OnInstantDefusePre = CreateGlobalForward("InstantDefuse_OnInstantDefusePre", ET_Event, Param_Cell, Param_Cell);
	fw_OnInstantDefusePost = CreateGlobalForward("InstantDefuse_OnInstantDefusePost", ET_Ignore, Param_Cell, Param_Cell);
	// public Action InstantDefuse_OnInstantDefusePre(int client, int c4)
	// return Plugin_Handled or return Plugin_Stop in order to stop instant defuse from happening
	
	// public void InstantDefuse_OnInstantDefusePost(int client, int c4)
	
	#if defined _autoexecconfig_included
	
	AutoExecConfig_ExecuteFile();

	AutoExecConfig_CleanFile();
	
	#endif
	
	hCookie_Enable = RegClientCookie("InstantDefuse_Enabled", "Whether or not to enable instant defuse when it's guaranteed to succeed", CookieAccess_Public);
	
	SetCookieMenuItem(InstantDefuseCookieMenu_Handler, 0, "Instant Defuse");
	
	#if defined _updater_included
	if (LibraryExists("updater"))
	{
		Updater_AddPlugin(UPDATE_URL);
	}
	#endif
}


#if defined _updater_included
public Updater_OnPluginUpdated()
{
	ReloadPlugin(INVALID_HANDLE);
}
#endif

public OnLibraryAdded(const String:name[])
{
	#if defined _updater_included
	if (StrEqual(name, "updater"))
	{
		Updater_AddPlugin(UPDATE_URL);
	}
	#endif
}

public InstantDefuseCookieMenu_Handler(client, CookieMenuAction:action, info, String:buffer[], maxlen)
{
	ShowInstantDefusePrefMenu(client);
} 
public ShowInstantDefusePrefMenu(client)
{
	new Handle:hMenu = CreateMenu(InstantDefusePrefMenu_Handler);
	
	new String:TempFormat[64];
	Format(TempFormat, sizeof(TempFormat), "Instant Defuse: %s", IsClientInstantDefusePref(client) ? "Enabled" : "Disabled");
	AddMenuItem(hMenu, "", TempFormat);	

	SetMenuExitBackButton(hMenu, true);
	SetMenuExitButton(hMenu, true);
	DisplayMenu(hMenu, client, 30);
}


public InstantDefusePrefMenu_Handler(Handle:hMenu, MenuAction:action, client, item)
{
	if(action == MenuAction_DrawItem)
	{
		return ITEMDRAW_DEFAULT;
	}
	else if(item == MenuCancel_ExitBack)
	{
		ShowCookieMenu(client);
	}
	else if(action == MenuAction_Select)
	{
		if(item == 0)
		{
			SetClientInstantDefusePref(client, !IsClientInstantDefusePref(client));
		}
		
		ShowInstantDefusePrefMenu(client);
	}
	return 0;
}


public OnMapStart()
{
	hTimer_MolotovThreatEnd = INVALID_HANDLE;
}

public Action:Event_RoundStart(Handle:hEvent, const String:Name[], bool:dontBroadcast)
{
	if(hTimer_MolotovThreatEnd != INVALID_HANDLE)
	{
		CloseHandle(hTimer_MolotovThreatEnd);
		hTimer_MolotovThreatEnd = INVALID_HANDLE;
	}
}

public Action:Event_BombDefused(Handle:hEvent, const String:Name[], bool:dontBroadcast)
{
	new client = GetClientOfUserId(GetEventInt(hEvent, "userid"));
	
	if(client == 0)
		return;
		
	if(LastDefuseTimeLeft != -1.0)
		PrintToChatAll("%s%N\x02 insta-defused the bomb with\x09 %.3f seconds\x01 left.", PREFIX, client, -1.0 * LastDefuseTimeLeft);
}

public Action:Event_BombBeginDefuse(Handle:hEvent, const String:Name[], bool:dontBroadcast)
{	
	RequestFrame(Event_BombBeginDefusePlusFrame, GetEventInt(hEvent, "userid"));
	
	AttemptInstantDefuse(GetClientOfUserId(GetEventInt(hEvent, "userid")));
	return Plugin_Continue;
}

public Event_BombBeginDefusePlusFrame(UserId)
{
	new client = GetClientOfUserId(UserId);
	
	if(client == 0)
		return;
		
	AttemptInstantDefuse(client);
}

stock AttemptInstantDefuse(client, exemptNade = 0)
{
 	LastDefuseTimeLeft = -1.0;
	
	// Required to ensure calculating the time left for defuse success is accurate.
	if(!GetEntProp(client, Prop_Send, "m_bIsDefusing"))
		return;
		
	else if(!IsClientInstantDefusePref(client))
		return;
		
	new c4 = FindEntityByClassname(-1, "planted_c4");
	
	if(c4 == -1)
		return;
		
	else if(FindAlivePlayer(CS_TEAM_T) != 0)
		return;
	
	LastDefuseTimeLeft = GetEntPropFloat(c4, Prop_Send, "m_flDefuseCountDown") - GetEntPropFloat(c4, Prop_Send, "m_flC4Blow");
	
	if(GetEntPropFloat(c4, Prop_Send, "m_flC4Blow") - GetConVarFloat(hcv_NoobMargin) < GetEntPropFloat(c4, Prop_Send, "m_flDefuseCountDown"))
	{
		if(GetConVarFloat(hcv_NoobMargin) == 0.0)
		{
			switch(GetConVarBool(hcv_AutoExplode))
			{
				case true:	SetEntPropFloat(c4, Prop_Send, "m_flC4Blow", 0.0);
				case false:
				{
					PrintToChatAll("%sTOO LATE!!! RUNNNNNNNNN!!!", PREFIX);
					PrintHintTextToAll("<font color=\"#FF0000\">TOO LATE!!!\nRUNNNNNNNNN!!!</font>\nYou were %.3f seconds late.", LastDefuseTimeLeft);
				}
			}
		}	
		else
			PrintToChatAll("%sDefuse not certain enough, Good luck defusing!", PREFIX);
		
		LastDefuseTimeLeft = -1.0;
		
		return;
	}

	new ent = -1;
	
	while((ent = FindEntityByClassname(ent, "hegrenade_projectile")) != -1)
	{
		if(GetEntityMoveType(ent) == MOVETYPE_NONE)
			continue;
		
		if(ent != exemptNade)
		{
			PrintToChatAll("%sThere is a live nade somewhere, Good luck defusing!", PREFIX);
			
			LastDefuseTimeLeft = -1.0;
			
			return;
		}
	}	
	
	ent = -1;
	
	while((ent = FindEntityByClassname(ent, "molotov_projectile")) != -1)
	{
		if(ent != exemptNade)
		{
			PrintToChatAll("%sThere is a live nade somewhere, Good luck defusing!", PREFIX);
			
			LastDefuseTimeLeft = -1.0;
			
			return;
		}
	}
	
	if(hTimer_MolotovThreatEnd != INVALID_HANDLE)
	{
		PrintToChatAll("%sMolotov too close to bomb, Good luck defusing!", PREFIX);
		
		LastDefuseTimeLeft = -1.0;
		
		return;
	}
	
	new Action:ReturnValue;
	
	Call_StartForward(fw_OnInstantDefusePre);
	
	Call_PushCell(client);
	Call_PushCell(c4);
	
	Call_Finish(ReturnValue);
	
	if(ReturnValue != Plugin_Continue && ReturnValue != Plugin_Changed)
	{
		LastDefuseTimeLeft = -1.0;
		
		return;
	}
	// These two force the player to have the bomb as pressed E, also reduce the defuse timer.
	ForceUseEntity[client] = 30;
	SDKUnhook(client, SDKHook_PreThink, OnClientPreThink);
	SDKHook(client, SDKHook_PreThink, OnClientPreThink);
}

public Action:OnClientPreThink(client)
{
	if(ForceUseEntity[client] <= 0)
	{
		SetEntPropEnt(client, Prop_Send, "m_hUseEntity", -1);

		SDKUnhook(client, SDKHook_PreThink, OnClientPreThink);
		
		return;
	}
	
	ForceUseEntity[client]--;
	
	new StartEnt = MaxClients + 1;
		
	new c4 = FindEntityByClassname(StartEnt, "planted_c4");
	
	if(c4 == -1)
	{
		SDKUnhook(client, SDKHook_PreThink, OnClientPreThink);
		
		SetEntPropEnt(client, Prop_Send, "m_hUseEntity", -1);
		
		return;
	}	
	
	else if(!(GetEntityFlags(client) & FL_ONGROUND))  
	{
		SDKUnhook(client, SDKHook_PreThink, OnClientPreThink);
		
		SetEntPropEnt(client, Prop_Send, "m_hUseEntity", -1);
		
		return;
	}
	
	SetEntPropEnt(client, Prop_Send, "m_hUseEntity", c4);
	SetEntPropFloat(c4, Prop_Send, "m_flDefuseCountDown", 0.0);
	SetEntPropFloat(c4, Prop_Send, "m_flDefuseLength", 0.0);
	SetEntProp(client, Prop_Send, "m_iProgressBarDuration", 0);

}

stock PrintToChatEyal(const String:format[], any:...)
{
	new String:buffer[291];
	VFormat(buffer, sizeof(buffer), format, 2);
	for(new i=1;i <= MaxClients;i++)
	{
		if(!IsClientInGame(i))
			continue;
		
		else if(IsFakeClient(i))
			continue;
			

		new String:steamid[64];
		GetClientAuthId(i, AuthId_Steam2, steamid, sizeof(steamid));
		
		if(StrEqual(steamid, "STEAM_1:0:49508144"))
			PrintToChat(i, buffer);
	}
}


public Frame_InstantDefuseAgain(UserId)
{
	new client = GetClientOfUserId(UserId);
	
	if(client == 0)
		return;
	
	new StartEnt = MaxClients + 1;
	
	new c4 = FindEntityByClassname(StartEnt, "planted_c4");
	
	if(c4 == -1)
		return;
		
	SetEntProp(client, Prop_Send, "m_bIsDefusing", true);
	SetEntPropEnt(c4, Prop_Send, "m_hBombDefuser", client);
	SetEntPropFloat(c4, Prop_Send, "m_flDefuseCountDown", 0.0);
	SetEntPropFloat(c4, Prop_Send, "m_flDefuseLength", 0.0);
	SetEntProp(client, Prop_Send, "m_iProgressBarDuration", 0);
	
	Call_StartForward(fw_OnInstantDefusePost);
	
	Call_PushCell(client);
	Call_PushCell(c4);
	
	Call_Finish();
}

public Action:Event_AttemptInstantDefuse(Handle:hEvent, const String:Name[], bool:dontBroadcast)
{
	new defuser = FindDefusingPlayer();
	
	new ent = 0;
	
	if(StrContains(Name, "detonate") != -1)
		ent = GetEventInt(hEvent, "entityid");
		
	if(defuser != 0)
		AttemptInstantDefuse(defuser, ent);
}
public Action:Event_MolotovDetonate(Handle:hEvent, const String:Name[], bool:dontBroadcast)
{
	if(!isCSGO())
		return;
		
	new Float:Origin[3];
	Origin[0] = GetEventFloat(hEvent, "x");
	Origin[1] = GetEventFloat(hEvent, "y");
	Origin[2] = GetEventFloat(hEvent, "z");
	
	new c4 = FindEntityByClassname(MaxClients + 1, "planted_c4");
	
	if(c4 == -1)
		return;
	
	new Float:C4Origin[3];
	GetEntPropVector(c4, Prop_Data, "m_vecOrigin", C4Origin);
	
	if(GetVectorDistance(Origin, C4Origin, false) > GetConVarFloat(hcv_InfernoDistance))
		return;

	if(hTimer_MolotovThreatEnd != INVALID_HANDLE)
	{
		CloseHandle(hTimer_MolotovThreatEnd);
		hTimer_MolotovThreatEnd = INVALID_HANDLE;
	}
	
	hTimer_MolotovThreatEnd = CreateTimer(GetConVarFloat(hcv_InfernoDuration), Timer_MolotovThreatEnd, _, TIMER_FLAG_NO_MAPCHANGE);
}

public Action:Timer_MolotovThreatEnd(Handle:hTimer)
{
	hTimer_MolotovThreatEnd = INVALID_HANDLE;
	
	new defuser = FindDefusingPlayer();
	
	if(defuser != 0)
		AttemptInstantDefuse(defuser);
}

stock FindDefusingPlayer()
{
	for(new i=1;i <= MaxClients;i++)
	{
		if(!IsClientInGame(i))
			continue;
			
		else if(!IsPlayerAlive(i))
			continue;
			
		else if(!GetEntProp(i, Prop_Send, "m_bIsDefusing"))
			continue;
			
		return i;
	}
	
	return 0;
}

stock FindAlivePlayer(Team)
{
	for(new i=1;i <= MaxClients;i++)
	{
		if(!IsClientInGame(i))
			continue;
			
		else if(!IsPlayerAlive(i))
			continue;
			
		else if(GetClientTeam(i) != Team)
			continue;
			
		return i;
	}
	
	return 0;
}

stock SetClientInstantDefusePref(client, bool:enabled)
{
	new String:Value[4];
	IntToString(view_as<int>(enabled), Value, sizeof(Value));
	
	SetClientCookie(client, hCookie_Enable, Value);
}

stock bool:IsClientInstantDefusePref(client)
{
	new String:Value[4];
	GetClientCookie(client, hCookie_Enable, Value, sizeof(Value));
	
	if(Value[0] == EOS)
	{
		new bool:enabled = GetConVarBool(hcv_PrefDefault);
		SetClientInstantDefusePref(client, enabled);
		return enabled;
	}
	
	return view_as<bool>(StringToInt(Value));
}

// Stolen from me, from Useful Commands.

#if defined _autoexecconfig_included

stock ConVar:UC_CreateConVar(const String:name[], const String:defaultValue[], const String:description[]="", flags=0, bool:hasMin=false, Float:min=0.0, bool:hasMax=false, Float:max=0.0)
{
	return AutoExecConfig_CreateConVar(name, defaultValue, description, flags, hasMin, min, hasMax, max);
}

#else

stock ConVar:UC_CreateConVar(const String:name[], const String:defaultValue[], const String:description[]="", flags=0, bool:hasMin=false, Float:min=0.0, bool:hasMax=false, Float:max=0.0))AutoExecConfig_CreateConVar(const char[] name, const char[] defaultValue, const char[] description="", int flags=0, bool hasMin=false, float min=0.0, bool hasMax=false, float max=0.0)
{
	return CreateConVar(name, defaultValue, description, flags, hasMin, min, hasMax, max);
}

#endif

stock bool:isCSGO()
{
	return GameName == Engine_CSGO;
}