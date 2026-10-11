"""Regenerate OB30_Signals.mq4 from OB30_Signals.mq5 (the code is identical except 3 lines)."""
s = open("OB30_Signals.mq5").read()
m = s.replace("OB30_Signals.mq5  -  Indicateur MT5 v3 (meme code que la version  |\n//| MT4 OB30_Signals.mq4)",
              "OB30_Signals.mq4  -  Indicateur MT4 v3 (meme code que la version  |\n//| MT5 OB30_Signals.mq5)")
m = m.replace("#property indicator_plots   0\n", "")
m = m.replace('IndicatorSetString(INDICATOR_SHORTNAME, "OB30 Signals");', 'IndicatorShortName("OB30 Signals");')
m = m.replace("#property indicator_chart_window\n", "#property indicator_chart_window\n#property indicator_buffers 0\n#property strict\n", 1)
open("OB30_Signals.mq4", "w").write(m)
print("OB30_Signals.mq4 regenerated")
