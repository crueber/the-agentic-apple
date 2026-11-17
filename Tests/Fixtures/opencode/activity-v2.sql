-- Synthetic OpenCode 2 store: only the columns the collector reads.
CREATE TABLE session_message (id text PRIMARY KEY, session_id text NOT NULL, type text NOT NULL, seq integer NOT NULL, time_created integer NOT NULL, time_updated integer NOT NULL, data text NOT NULL);
-- "today" in the tests is anchored at TODAY_MS (local midnight), substituted at runtime.
INSERT INTO session_message VALUES ('m1','s1','user',1,TODAY_MS+1000,TODAY_MS+1000,'{"text":"demo prompt","time":{"created":0}}');
INSERT INTO session_message VALUES ('m2','s1','assistant',2,TODAY_MS+2000,TODAY_MS+2000,'{"tokens":{"input":100,"output":50,"reasoning":10,"cache":{"read":200,"write":40}}}');
INSERT INTO session_message VALUES ('m3','s1','user',3,TODAY_MS+3000,TODAY_MS+3000,'{"text":"second demo prompt"}');
INSERT INTO session_message VALUES ('m4','s1','assistant',4,TODAY_MS+4000,TODAY_MS+4000,'{"tokens":{"input":1,"output":2,"reasoning":0,"cache":{"read":0,"write":0}}}');
INSERT INTO session_message VALUES ('m5','s1','synthetic',5,TODAY_MS+5000,TODAY_MS+5000,'{"text":"not a prompt"}');
-- Yesterday: must not count.
INSERT INTO session_message VALUES ('m0','s0','user',1,TODAY_MS-1000,TODAY_MS-1000,'{"text":"old"}');
INSERT INTO session_message VALUES ('m00','s0','assistant',2,TODAY_MS-500,TODAY_MS-500,'{"tokens":{"input":9999,"output":9999}}');
