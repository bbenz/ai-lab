"""Sample reviews for the LAB723 lab client, load generator, and Ray batch job.

The text was written for this lab.
"""

import random

# Short product and service reviews, mixed positive and negative, 10 to 30 words each.
SAMPLES = [
    "The checkout was quick and the support team answered my question within minutes.",
    "My order arrived two days late and the box was crushed on one side.",
    "Setup took five minutes, and the app found my device on the first try.",
    "The battery barely lasts half a day, which makes this phone hard to recommend.",
    "I love how quiet this dishwasher is. I can finally hold a conversation in the kitchen.",
    "Customer service kept me on hold for an hour and then disconnected the call.",
    "The hotel staff upgraded our room for free and remembered our names all week.",
    "The latest update deleted my saved settings and now the app crashes at startup.",
    "Great value for the price: sturdy, easy to clean, and it looks better than the photos.",
    "The instructions were missing a page, so assembly took the whole afternoon.",
    "Our team adopted the new dashboard in a day because everything is where you expect it.",
    "The headphones sound muddy, and the left ear cup started rattling after a week.",
    "Fast shipping, careful packaging, and a handwritten thank-you note in the box.",
    "I asked for a refund three times and still haven't heard back from anyone.",
    "This coffee maker brews a full pot in four minutes and keeps it hot for hours.",
    "The subscription price went up again without any new features to justify it.",
    "The tour guide was funny, patient, and knew the history of every building we passed.",
    "Half of the parts in the kit didn't fit, and the replacement pieces never arrived.",
    "The keyboard feels solid, the keys are quiet, and the battery lasts for months.",
    "The restaurant was loud, the food was cold, and the bill had two items we never ordered.",
    "Returning the jacket was easy: I printed a label and dropped it off on my way to work.",
    "The website logged me out every few minutes, so I gave up and bought it elsewhere.",
    "These running shoes are light and comfortable, even after a ten-mile run.",
    "The rental car smelled of smoke and had a warning light on the dashboard the whole trip.",
    "Our internet has been fast and stable since the technician replaced the old router.",
    "The blender leaks from the bottom every time I use it, and it's only a month old.",
    "I was nervous about the procedure, but the nurses explained every step and kept me calm.",
    "The concert started an hour late and the sound cut out twice during the show.",
    "The new version of the app is faster, cleaner, and finally supports dark mode.",
    "The warranty claim was rejected because of a tiny scratch that was there on delivery.",
    "The library staff helped me find three books I didn't even know existed.",
    "The vacuum loses suction after five minutes and the filter clogs constantly.",
    "Every dish we tried was excellent, and the server's recommendations were spot on.",
    "The printer refuses to connect to the network, no matter what the manual suggests.",
    "The online course was well organized, and the exercises built on each other nicely.",
    "The movie was two hours of loud explosions with no story worth following.",
    "Our flight was rebooked automatically, and the airline sent meal vouchers right away.",
    "The paint peeled within a month and the store refused to take any responsibility.",
    "This tent went up in ten minutes and kept us completely dry through a storm.",
    "The gym is always crowded, half the machines are broken, and the showers are cold.",
]

_SUBJECTS = [
    "The delivery", "The mobile app", "Customer support", "The return process", "The firmware update",
    "The hotel room", "The checkout page", "The subscription plan", "The wireless headphones", "The coffee maker",
    "The rental car", "The online course", "The kitchen blender", "The fitness tracker", "The train journey",
    "The smart thermostat", "The pizza", "The office chair", "The video call service", "The museum tour",
]
_POSITIVE = [
    "was faster than I expected", "worked perfectly on the first try", "made the whole experience easy",
    "exceeded everything the description promised", "was friendly and genuinely helpful", "felt solid and well made",
    "saved me a lot of time", "was simple to set up", "was a pleasant surprise", "kept working without a single problem",
]
_NEGATIVE = [
    "stopped working after a week", "was confusing and painfully slow", "took three phone calls to sort out",
    "felt cheap and broke quickly", "was nothing like the photos", "arrived damaged and incomplete",
    "crashed every time I opened it", "was far too expensive for what it does", "made a simple task frustrating",
    "ignored every complaint I sent",
]
_POSITIVE_ENDINGS = [
    "and I would happily buy it again.", "so I recommended it to my whole team.", "which made my week.",
    "and the price was fair.", "so I left a five-star review.", "and I can't imagine going back.",
]
_NEGATIVE_ENDINGS = [
    "and I asked for a refund.", "so I won't order from them again.", "which wasted my entire morning.",
    "and support never replied.", "so I returned it the next day.", "and I regret buying it.",
]


def make_batch(count: int = 2000, seed: int = 723) -> list:
    """Returns the same list of synthetic reviews every time, for the Ray batch job."""
    rng = random.Random(seed)
    batch = []
    for _ in range(count):
        if rng.random() < 0.5:
            phrase, ending = rng.choice(_POSITIVE), rng.choice(_POSITIVE_ENDINGS)
        else:
            phrase, ending = rng.choice(_NEGATIVE), rng.choice(_NEGATIVE_ENDINGS)
        batch.append(f"{rng.choice(_SUBJECTS)} {phrase}, {ending}")
    return batch
