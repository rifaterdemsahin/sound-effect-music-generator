import requests
import yaml
import os

API_KEY = os.getenv("ELEVENLABS_API_KEY")
API_URL = "https://api.elevenlabs.io/v1/sound-effects/generate"

with open("door_sounds.yaml", "r") as f:
    data = yaml.safe_load(f)

for item in data["door_sounds"]:
    desc = item["description"]
    payload = {"description": desc, "format": "mp3"}
    headers = {"Authorization": f"Bearer {API_KEY}", "Content-Type": "application/json"}
    print(f"[DEBUG] Sending sound generation request to {API_URL}")
    print(f"[DEBUG] Payload: {payload}")
    response = requests.post(API_URL, json=payload, headers=headers)
    if response.ok:
        fname = desc.replace(" ", "_") + ".mp3"
        with open(fname, "wb") as out:
            out.write(response.content)
        print(f"Saved: {fname}")
    else:
        print(f"Error generating sound for: {desc}")
