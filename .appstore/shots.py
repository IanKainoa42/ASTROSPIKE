import jwt, time, json, urllib.request, urllib.error, sys, os, hashlib
KEY_ID="6H24WZ2RQ5"; ISSUER="7642a25e-aca7-402d-8b7d-de18dfef1756"; APP="6805938755"
LOC="3cebf1c3-2774-4307-a1f7-fe245da72898"
p8=open(f"/Users/ianrichardson/.appstoreconnect/private_keys/AuthKey_{KEY_ID}.p8").read()
BASE="https://api.appstoreconnect.apple.com"
def tok():
    return jwt.encode({"iss":ISSUER,"iat":int(time.time()),"exp":int(time.time())+900,"aud":"appstoreconnect-v1"},p8,algorithm="ES256",headers={"kid":KEY_ID})
def api(method, path, body=None):
    data=json.dumps(body).encode() if body is not None else None
    req=urllib.request.Request(BASE+path, data=data, method=method,
        headers={"Authorization":f"Bearer {tok()}","Content-Type":"application/json"})
    try:
        r=urllib.request.urlopen(req); raw=r.read()
        return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        print("HTTP",e.code,method,path); print(e.read().decode()[:1200]); sys.exit(1)
if __name__=="__main__":
    print(json.dumps(api("GET", f"/v1/appStoreVersionLocalizations/{LOC}/appScreenshotSets?limit=20"), indent=1)[:3000])
