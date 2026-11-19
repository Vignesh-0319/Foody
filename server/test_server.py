import json
import tempfile
import unittest
from contextlib import closing
from pathlib import Path
from threading import Thread
from urllib.request import Request, urlopen
from urllib.error import HTTPError
import server

class FoodyIntegration(unittest.TestCase):
    def setUp(self):
        temp=tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        server.DB=str(Path(temp.name)/"test.sqlite3")
        server.initialize()
        self.http=server.ThreadingHTTPServer(("127.0.0.1",0),server.Handler)
        Thread(target=self.http.serve_forever,daemon=True).start()
        self.addCleanup(self.http.server_close)
        self.addCleanup(self.http.shutdown)

    def call(self, key, path="/state", **payload):
        request=Request("http://127.0.0.1:%s%s"%(self.http.server_port,path),
                        data=json.dumps(payload).encode() if payload else None,
                        headers={"Authorization":"Bearer "+key*64,"Content-Type":"application/json"})
        with urlopen(request) as response:
            return json.load(response)

    def test_two_students_and_persistence(self):
        self.call("a","/profile",uni=server.UNIS[0],name="Anya",budget=150)
        self.call("a","/vote",meal="raj",paid=178,verdict="Must try",filling=True)
        self.call("a","/vote",meal="raj",paid=190,verdict="Go for it",filling=False)
        for _ in range(2):
            self.call("a","/comment",meal="raj",body="Good portion.",nonce="same-request")
        view=self.call("b")
        meal=view["meals"][0]
        self.assertEqual(meal["counts"],[7,5,1])
        self.assertEqual((meal["high"],meal["full"],meal["mine"]),(190,9,None))
        self.assertEqual([(c["author"],c["body"]) for c in meal["comments"]],[("Anya","Good portion.")])
        self.assertIsNone(view["profile"]["uni"])
        server.initialize()
        self.assertEqual(self.call("a")["profile"]["budget"],150)
        with self.assertRaises(HTTPError) as err:
            self.call("b","/vote",meal="raj",paid=-1,verdict="Skip it",filling=True)
        self.assertEqual(err.exception.code,400)
if __name__=="__main__":
    unittest.main()
