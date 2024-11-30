from fastapi import FastAPI, Request
from typing import Dict

app = FastAPI()

@app.get("/headers")
async def get_headers(request: Request) -> Dict:
    return {"headers": dict(request.headers)}

@app.get("/")
async def root():
    return {"message": "Welcome to the Headers API"}