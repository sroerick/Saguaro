import sys, time
sys.path.insert(0, str(__import__("pathlib").Path(__file__).resolve().parent.parent))
import bridge as b

rec = b.pick_session()
print("picked:", rec)
conv = rec["conversation"]
wm = max((r["seq"] for r in b.all_records(conv)), default=0)
print("watermark:", wm)
b.run([b.A["bin"], "localgroup", "tell", rec["session"], "(+ 40 2)"])
t0 = time.time()
for _ in range(30):
    time.sleep(1.5)
    cur = next(r for r in b.status_records() if r["session"] == rec["session"])
    if cur["idle"] and not cur["active"]:
        break
new = [r for r in b.all_records(conv) if r["seq"] > wm]
print("elapsed %.1fs, new records:" % (time.time() - t0), [(r["seq"], r["type"]) for r in new])
print("REPLY:", repr(b.reply_text(new)))
