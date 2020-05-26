#!/usr/bin/env python3

import os, sys
import requests, json
import urllib.request

def die(msg):
    print("die: " + msg)
    sys.exit(1)

VERBOSE=os.getenv('VERBOSE', None)

MISSING_ENV_VARS=[]

ORG_ID=os.getenv('ORG_ID')
API_KEY=os.getenv('API_KEY')

OWNER_ID_OR_EMAIL=os.getenv('OWNER_ID_OR_EMAIL')

PRIVATE_IP=os.getenv('PRIVATE_IP')
PUBLIC_IP=os.getenv('PUBLIC_IP')

if ORG_ID            == None: MISSING_ENV_VARS.append('ORG_ID')
if API_KEY           == None: MISSING_ENV_VARS.append('API_KEY')
if OWNER_ID_OR_EMAIL == None: MISSING_ENV_VARS.append('OWNER_ID_OR_EMAIL')
if PRIVATE_IP        == None: MISSING_ENV_VARS.append('PRIVATE_IP')
if PUBLIC_IP         == None: MISSING_ENV_VARS.append('PUBLIC_IP')

if len(MISSING_ENV_VARS) > 0:
    die("Missing env var definitions: " + " ".join(MISSING_ENV_VARS))

headers = {
    'Authorization': "Bearer " + ORG_ID + ":" + API_KEY,
    'Accept': 'application/json',
    'Content-Type': 'application/json'
}

if VERBOSE != None:
    print(f"headers: {headers}")

def response(url):
    with urllib.request.urlopen(url, headers=headers) as response:
        return response.read()

    res = response(url)
    ret = json.loads(res)
    if VERBOSE:
        print(f"get({url}) ==> {ret}")
    return ret

def getEvents():
    url = "https://app.strigo.io/api/v1/events"
    res = requests.get(url, headers=headers)
    #print(type(res))
    #print(res)
    return res.json()

def getMyEventField( owner_id_or_email, field='id', status='live' ):
    events = getEvents()

    #print(events)

    for ev in events['data']:
        #print(ev)
        if ev['status'] == status and \
                (ev['owner']['email'] == owner_id_or_email or \
                 ev['owner']['id'] == owner_id_or_email):
            if field == '*':
                if VERBOSE: print(f"event={json.dumps(ev,  indent=2, sort_keys=True)}")
            else:
                if VERBOSE: print(f"event[{field}]={ev[field]}")
                return ev[field]

def getEventWorkspaces( eventId ):
    url = f"https://app.strigo.io/api/v1/events/{eventId}/workspaces" 
    res = requests.get(url, headers=headers)
    return res.json()

def getMyWorkSpaceDetails( eventId ):
    workspaces = getEventWorkspaces( eventId )
    if VERBOSE: print(f"workspaces={workspaces}")

    myWorkspace=None

    for ws_data in workspaces['data']:
        workspaceId=ws_data['id']
        workspacePrivateIps=[]
        workspacePublicIps=[]
        if VERBOSE: print(f"workspaceId={workspaceId}")

        owner=ws_data['owner']
        owner_id=owner['id']
        owner_email=owner['email']
        if VERBOSE: print(f"ownerId={owner_id} ownerEMail={owner_email}")

        url = f"https://app.strigo.io/api/v1/events/{eventId}/workspaces/{workspaceId}/resources"
        workspace = requests.get(url, headers=headers).json()
        if VERBOSE: print(f"workspace={workspace}")
        for lab_inst in workspace['data']:
            lab_instance_id=lab_inst['id']
            private_ip=lab_inst['private_ip']
            public_ip=lab_inst['public_ip']
            if VERBOSE: print(f"lab_id={lab_instance_id} private_ip=${private_ip} public_ip={public_ip}")

            workspacePrivateIps.append(private_ip)
            workspacePublicIps.append(public_ip)

            if private_ip == PRIVATE_IP:
                myWorkspace=workspaceId
                if VERBOSE:
                    print(f"FOUND my workspace: ID={workspaceId}")
                    print(f"-- lab_instance_id={lab_instance_id}")
                    print(f"-- private_ip={private_ip}")
                    print(f"-- public_ip={public_ip}")

        if myWorkspace:
            return ( owner_id, owner_email, workspaceId, workspacePrivateIps, workspacePublicIps )

    # PRIVATE_IP=os.getenv('PRIVATE_IP')
    #return res.json()
    return ( None, None, None, None, None )

def getNumberOfNodes( eventId ):
    ( ownerId, ownerEmail, workspaceId, workspacePrivateIps, workspacePublicIps ) = \
        getMyWorkSpaceDetails( eventId )
    return len(workspacePrivateIps)

def getMyNodeIndex( eventId ):
    ( ownerId, ownerEmail, workspaceId, workspacePrivateIps, workspacePublicIps ) = \
        getMyWorkSpaceDetails( eventId )

    for idx in range(len(workspacePrivateIps)):
        private_ip = workspacePrivateIps[idx]
        if private_ip == PRIVATE_IP:
            return idx

    return -1

# Shift off 'prog' argument:
prog=sys.argv[0]; sys.argv=sys.argv[1:]

while len(sys.argv) > 0:
    arg=sys.argv[0]; sys.argv=sys.argv[1:]

    if arg == '-v':
        VERBOSE=True

    if arg == '-o': # Specify owner_id or owner_email to use
        arg=sys.argv[0]; sys.argv=sys.argv[1:]
        OWNER_ID_OR_EMAIL=arg

    if arg == '-e': # Return event_id of current event
        eventId = getMyEventField( OWNER_ID_OR_EMAIL )
        #print(f"eventId={eventId}")
        print(eventId)

    if arg == '-c': # Return class_id of current event
        classId = getMyEventField( OWNER_ID_OR_EMAIL, field='class_id' )
        #print(f"classId={classId}")
        print(classId)

    if arg == '-W': # Return workspace_id's of all workspaces
        eventId = getMyEventField( OWNER_ID_OR_EMAIL )
        if VERBOSE: print(f"eventId={eventId}")
        workspaces = getEventWorkspaces( eventId )
        if VERBOSE: print(f"workspaces={workspaces}")
        for w in workspaces['data']:
            print(w['id'])

    if arg == '-w': # Return workspace_id of current workspace (this student or owner)
        eventId = getMyEventField( OWNER_ID_OR_EMAIL )
        if VERBOSE: print(f"eventId={eventId}")
        ( ownerId, ownerEmail, workspaceId, workspacePrivateIps, workspacePublicIps ) = \
            getMyWorkSpaceDetails( eventId )
        print(workspaceId)

    if arg == '-oid': # Return owner_id of current workspace (this student or owner)
        eventId = getMyEventField( OWNER_ID_OR_EMAIL )
        if VERBOSE: print(f"eventId={eventId}")
        ( ownerId, ownerEmail, workspaceId, workspacePrivateIps, workspacePublicIps ) = \
            getMyWorkSpaceDetails( eventId )
        print(ownerId)

    if arg == '-oem': # Return owner_email of current workspace (this student or owner)
        eventId = getMyEventField( OWNER_ID_OR_EMAIL )
        if VERBOSE: print(f"eventId={eventId}")
        ( ownerId, ownerEmail, workspaceId, workspacePrivateIps, workspacePublicIps ) = \
            getMyWorkSpaceDetails( eventId )
        print(ownerEMail)

    if arg == '-ips': # Return ips of VMs of current workspace (this student or owner)
        eventId = getMyEventField( OWNER_ID_OR_EMAIL )
        if VERBOSE: print(f"eventId={eventId}")
        ( ownerId, ownerEmail, workspaceId, workspacePrivateIps, workspacePublicIps ) = \
            getMyWorkSpaceDetails( eventId )

        if len(sys.argv) > 0:
            idx=int(sys.argv[0])
            print(f"{workspacePrivateIps[idx]},{workspacePublicIps[idx]}")
            sys.exit(0)

        print( workspacePrivateIps, workspacePublicIps )
        sys.exit(0)

    if arg == '-idx': # Get index of the current VM e.g. so that 1 is Master, 2 is Slave etc ...
        eventId = getMyEventField( OWNER_ID_OR_EMAIL )
        if VERBOSE: print(f"eventId={eventId}")
        idx = getMyNodeIndex( eventId )
        print(idx)

    if arg == '-nodes': # Get number of nodes/VMs for the current student workspace
        eventId = getMyEventField( OWNER_ID_OR_EMAIL )
        if VERBOSE: print(f"eventId={eventId}")
        nodes = getNumberOfNodes( eventId )
        print(nodes)

