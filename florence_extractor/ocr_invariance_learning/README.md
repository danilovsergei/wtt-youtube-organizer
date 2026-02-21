# OCR Variance Analysis & Verification

AI prompt and `verify_generated_testdata.go` designed to quickly find OCR model failures in the logs and generate correct dataset to re-learn the model

## Workflow Overview
While in the `$HOME/.config/wtt-youtube-organizer/log/` dir , use prompt `promt_to_find_ocr_invariance.txt` with gemini or similar 
The process follows a three-stage pipeline to ensure data integrity:
AI will find all the `OCR_NAME_VARIANCE` , fetch the correct player names from the images and generate correct expected testdata.csv

Use `verify_generated_testdata.go` to manually verify that generated testdata.csv is correct\
It will print incorrect detection in the log and correct result AI found
