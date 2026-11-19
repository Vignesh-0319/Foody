"""Foody local development API. Run with Python 3.9 or newer."""
import hashlib
import json
import os
import re
import sqlite3
from contextlib import closing
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

DB = os.getenv("FOODY_DB", str(Path(__file__).with_name("foody.sqlite3")))
UNIS = ["Chitkara University", "UPES Dehradun"]
VERDICTS = ["Must try", "Go for it", "Skip it"]
MENU = [
    ("raj",0,"Rajma rice","Campus Kitchen","🍛",175,185,5,[7,4,1],9),
    ("dosa",0,"Masala dosa","Tiffin Corner","🥞",110,130,8,[5,3,1],7),
    ("thali",0,"Paneer thali","Thali House","🍱",210,230,7,[8,2,1],10),
    ("idli",1,"Idli & sambar","Morning Mess","🍲",90,105,4,[4,3,1],6),
    ("roll",1,"Paneer roll","Roll Counter","🌯",145,160,6,[5,4,0],7),
]
IDS = {m[0] for m in MENU}

def connect():
    db = sqlite3.connect(DB, timeout=8)
    db.row_factory = sqlite3.Row
    db.execute("PRAGMA foreign_keys=ON")
    return db

def initialize():
    with closing(connect()) as db:
        db.executescript("""
        PRAGMA journal_mode=WAL;
        CREATE TABLE IF NOT EXISTS people(id TEXT PRIMARY KEY, name TEXT NOT NULL DEFAULT 'Student', uni TEXT, budget INTEGER NOT NULL DEFAULT 200);
        CREATE TABLE IF NOT EXISTS votes(person TEXT REFERENCES people(id), meal TEXT, verdict TEXT, paid INTEGER, filling INTEGER, PRIMARY KEY(person,meal));
        CREATE TABLE IF NOT EXISTS comments(seq INTEGER PRIMARY KEY, person TEXT REFERENCES people(id), meal TEXT, body TEXT, nonce TEXT, UNIQUE(person,nonce));
        """)

def snapshot(db, person):
    profile=dict(db.execute("SELECT name,uni,budget FROM people WHERE id=?",(person,)).fetchone())
    meals=[]
    for mid,uni,name,restaurant,icon,lo,hi,minutes,seed,full in MENU:
        counts=seed.copy()
        mine=None
        for v in db.execute("SELECT * FROM votes WHERE meal=?",(mid,)):
            counts[VERDICTS.index(v["verdict"])]+=1
            full+=v["filling"]
            lo,hi=min(lo,v["paid"]),max(hi,v["paid"])
            if v["person"]==person:
                mine=dict(verdict=v["verdict"],paid=v["paid"],filling=bool(v["filling"]))
        comments=[dict(r) for r in db.execute("SELECT seq AS id,name AS author,body FROM comments JOIN people ON people.id=comments.person WHERE meal=? ORDER BY seq DESC LIMIT 100",(mid,))]
        meals.append(dict(id=mid,uni=UNIS[uni],name=name,restaurant=restaurant,icon=icon,low=lo,high=hi,minutes=minutes,counts=counts,full=full,mine=mine,comments=comments))
    return dict(universities=UNIS,profile=profile,meals=meals)

def valid_text(value,limit):
    return isinstance(value,str) and 0<len(value.strip())<=limit

def apply(db,person,path,data):
    if path=="/profile":
        for key,value in data.items():
            if key=="name" and valid_text(value,48): value=value.strip()
            elif key=="uni" and value in UNIS: pass
            elif key=="budget" and type(value) is int and 100<=value<=250 and value%50==0: pass
            else: raise ValueError("Check your profile values.")
            db.execute("UPDATE people SET "+key+"=? WHERE id=?",(value,person))
        return
    meal=data.get("meal")
    if meal not in IDS: raise ValueError("Unknown meal.")
    if path=="/vote":
        verdict,paid,filling=(data.get(k) for k in ("verdict","paid","filling"))
        if verdict not in VERDICTS or type(paid) is not int or not 1<=paid<=10000 or type(filling) is not bool:
            raise ValueError("Choose a verdict, portion and valid price.")
        db.execute("INSERT INTO votes VALUES(?,?,?,?,?) ON CONFLICT(person,meal) DO UPDATE SET verdict=excluded.verdict,paid=excluded.paid,filling=excluded.filling",(person,meal,verdict,paid,filling))
    elif path=="/comment":
        body,nonce=data.get("body"),data.get("nonce")
        if not valid_text(body,500) or not valid_text(nonce,64): raise ValueError("Use 1–500 characters.")
        db.execute("INSERT INTO comments(person,meal,body,nonce) VALUES(?,?,?,?) ON CONFLICT(person,nonce) DO NOTHING",(person,meal,body.strip(),nonce))

class Handler(BaseHTTPRequestHandler):
    def send_json(self,status,data):
        raw=json.dumps(data,ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type","application/json; charset=utf-8")
        self.send_header("Content-Length",str(len(raw)))
        self.send_header("Cache-Control","no-store")
        self.end_headers()
        self.wfile.write(raw)

    def dispatch(self,write=False):
        if self.path not in (("/profile","/vote","/comment") if write else ("/state",)):
            return self.send_json(404,{"error":"Unknown route"})
        auth=self.headers.get("Authorization","")
        if not re.fullmatch(r"Bearer [A-Fa-f0-9]{64}",auth):
            return self.send_json(401,{"error":"Device credential required"})
        person=hashlib.sha256(auth.encode()).hexdigest()
        try:
            data={}
            if write:
                size=int(self.headers.get("Content-Length","0"))
                if not 0<size<=8192: raise ValueError("Invalid request size")
                data=json.loads(self.rfile.read(size))
                if not isinstance(data,dict): raise ValueError("Expected an object")
            with closing(connect()) as db, db:
                db.execute("INSERT OR IGNORE INTO people(id) VALUES(?)",(person,))
                if write: apply(db,person,self.path,data)
                state=snapshot(db,person)
            self.send_json(200,state)
        except (ValueError,TypeError) as exc:
            self.send_json(400,{"error":str(exc)})
        except sqlite3.Error:
            self.send_json(503,{"error":"Storage temporarily unavailable. Try again."})

    def do_GET(self): self.dispatch()
    def do_POST(self): self.dispatch(True)

if __name__=="__main__":
    initialize()
    host=os.getenv("FOODY_HOST","127.0.0.1")
    port=int(os.getenv("FOODY_PORT","8787"))
    print(f"Foody API listening on http://{host}:{port}",flush=True)
    ThreadingHTTPServer((host,port),Handler).serve_forever()
