"""从任意目录启动：python tools/radar_viz/run.py [--sim STEP|CONT] ...（参数同 python -m radar_viz）

直接运行脚本时 Python 会把本文件所在目录加入 sys.path，所以不用设 PYTHONPATH。
"""
from radar_viz.__main__ import main

if __name__ == "__main__":
    main()
