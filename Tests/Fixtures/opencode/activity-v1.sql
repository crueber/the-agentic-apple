-- Synthetic OpenCode 1 store.
CREATE TABLE message (id text PRIMARY KEY, session_id text NOT NULL, time_created integer NOT NULL, time_updated integer NOT NULL, data text NOT NULL);
INSERT INTO message VALUES ('m1','s1',TODAY_MS+1000,TODAY_MS+1000,'{"role":"user"}');
INSERT INTO message VALUES ('m2','s1',TODAY_MS+2000,TODAY_MS+2000,'{"role":"assistant","tokens":{"input":10,"output":20,"reasoning":0,"cache":{"read":5,"write":0}}}');
INSERT INTO message VALUES ('m0','s0',TODAY_MS-1000,TODAY_MS-1000,'{"role":"user"}');
