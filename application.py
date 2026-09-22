from flask import Flask

application = Flask(__name__)

@application.route("/")
def index():
    return "Hello from p2vf32dx Elastic Beanstalk CI-CD verification-2026092219095114019"