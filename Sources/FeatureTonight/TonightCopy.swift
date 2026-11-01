import Foundation
import FeatureTonightCore

/// Every sentence "Tonight" shows. The core returns structured reasons; this
/// file phrases them as whole sentences so each language can reorder freely.
enum TonightCopy {
    static func genre(_ genre: TonightGenre) -> String {
        switch genre {
        case .action: return String(localized: "Action", comment: "Tonight: film genre")
        case .adventure: return String(localized: "Adventure", comment: "Tonight: film genre")
        case .animation: return String(localized: "Animation", comment: "Tonight: film genre")
        case .comedy: return String(localized: "Comedy", comment: "Tonight: film genre")
        case .crime: return String(localized: "Crime", comment: "Tonight: film genre")
        case .documentary: return String(localized: "Documentary", comment: "Tonight: film genre")
        case .drama: return String(localized: "Drama", comment: "Tonight: film genre")
        case .family: return String(localized: "Family", comment: "Tonight: film genre")
        case .fantasy: return String(localized: "Fantasy", comment: "Tonight: film genre")
        case .history: return String(localized: "History", comment: "Tonight: film genre")
        case .horror: return String(localized: "Horror", comment: "Tonight: film genre")
        case .music: return String(localized: "Music", comment: "Tonight: film genre")
        case .mystery: return String(localized: "Mystery", comment: "Tonight: film genre")
        case .romance: return String(localized: "Romance", comment: "Tonight: film genre")
        case .scienceFiction: return String(localized: "Science Fiction", comment: "Tonight: film genre")
        case .thriller: return String(localized: "Thriller", comment: "Tonight: film genre")
        case .war: return String(localized: "War", comment: "Tonight: film genre")
        case .western: return String(localized: "Western", comment: "Tonight: film genre")
        }
    }

    static func mode(_ mode: TonightMode) -> String {
        switch mode {
        case .firstWatch: return String(localized: "First Watch", comment: "Tonight: request mode, a film not seen before")
        case .rewatch: return String(localized: "Rewatch", comment: "Tonight: request mode, a film seen before")
        }
    }

    static func runtime(_ minutes: Int?) -> String {
        switch minutes {
        case nil: return String(localized: "Any Length", comment: "Tonight: runtime filter, no limit")
        case let minutes?: return String(localized: "Up to \(minutes) min", comment: "Tonight: runtime filter with a maximum in minutes")
        }
    }

    static func quick(_ rating: TonightQuickRating) -> String {
        switch rating {
        case .good: return String(localized: "good", comment: "Tonight: quick verdict inside a sentence, as in 'you marked X as good'")
        case .okay: return String(localized: "okay", comment: "Tonight: quick verdict inside a sentence, as in 'you marked X as okay'")
        case .bad: return String(localized: "bad", comment: "Tonight: quick verdict inside a sentence, as in 'you marked X as bad'")
        }
    }

    private static func verdictSentence(_ verdict: TonightVerdict) -> String {
        if let rating = verdict.rating {
            return String(localized: "Because you rated \(verdict.title) \(rating).", comment: "Tonight reason: one film and the viewer's 1-10 rating")
        }
        if verdict.favorite {
            return String(localized: "Because \(verdict.title) is one of your favorites.", comment: "Tonight reason: a favorite film without a rating")
        }
        if let quick = verdict.quick {
            return String(localized: "Because you marked \(verdict.title) as \(Self.quick(quick)).", comment: "Tonight reason: one film and a quick verdict (good/okay/bad)")
        }
        return String(localized: "Because you watched \(verdict.title).", comment: "Tonight reason: one watched film without a rating")
    }

    static func reason(_ reason: TonightReason) -> String {
        switch reason {
        case let .rated(verdicts, sameDirector):
            var text: String
            if verdicts.count >= 2, let a = verdicts[0].rating, let b = verdicts[1].rating {
                text = String(
                    localized: "Because you rated \(verdicts[0].title) \(a) and \(verdicts[1].title) \(b).",
                    comment: "Tonight reason: two films with the viewer's 1-10 ratings"
                )
            } else if let first = verdicts.first {
                text = verdictSentence(first)
                if verdicts.count >= 2 {
                    text += " " + String(localized: "Also based on \(verdicts[1].title).", comment: "Tonight reason: a second supporting film")
                }
            } else {
                text = ""
            }
            if let sameDirector {
                text += " " + String(localized: "Also by \(sameDirector).", comment: "Tonight reason: the suggestion shares the director")
            }
            return text
        case let .watchedRepeatedly(titles):
            if titles.count >= 2 {
                return String(localized: "You've watched \(titles[0]) and \(titles[1]) several times; this film shares genre or director with them.", comment: "Tonight reason: two films watched repeatedly")
            }
            return String(localized: "You've watched \(titles.first ?? "") several times; this film shares its genre or director.", comment: "Tonight reason: one film watched repeatedly")
        case let .watched(titles):
            if titles.count >= 2 {
                return String(localized: "Might suit your history: you've watched \(titles[0]) and \(titles[1]).", comment: "Tonight reason: two films watched once, no rating; careful wording")
            }
            return String(localized: "Might suit your history: you've watched \(titles.first ?? "").", comment: "Tonight reason: one film watched once, no rating; careful wording")
        case let .requestFit(fit):
            return requestFit(fit)
        case .onWatchlist:
            return String(localized: "It's on your watchlist and matches your filters.", comment: "Tonight reason")
        case .matchesFilters:
            return String(localized: "Matches your filters; nothing in your history is close to it yet.", comment: "Tonight reason: no evidence available")
        case let .rewatch(lead, years):
            var text = rewatchLead(lead)
            if let years {
                text += " " + String(localized: "You last watched it \(years) years ago.", comment: "Tonight reason: years since the last viewing, at least two")
            }
            return text
        case let .written(text):
            return text
        }
    }

    static func requestFit(_ fit: TonightRequestFit) -> String {
        switch fit {
        case .christmas:
            return String(localized: "It's set at Christmas, as you asked.", comment: "Tonight reason: the mood asked for Christmas")
        case .winter:
            return String(localized: "A wintry setting, as you asked.", comment: "Tonight reason: the mood asked for winter or snow")
        case let .decade(year):
            return String(localized: "From \(String(year)), matching the decade you asked for.", comment: "Tonight reason: year matches a requested decade")
        case let .director(name):
            return String(localized: "By \(name), as you asked.", comment: "Tonight reason: director named in the request")
        case let .genreKeyword(genre):
            return String(localized: "Your word “\(Self.genre(genre))” matches its genre.", comment: "Tonight reason: a genre named in free text")
        case let .keyword(word):
            return String(localized: "Your word “\(word)” is one of its themes.", comment: "Tonight reason: a theme keyword named in free text")
        case let .overviewWord(word):
            return String(localized: "Your word “\(word)” appears in its synopsis.", comment: "Tonight reason: a word from the free text appears in the synopsis")
        case let .referenceDirector(reference, director):
            return String(localized: "Directed by \(director), like \(reference).", comment: "Tonight reason: same director as the chosen reference film")
        case let .referenceGenre(reference, genre):
            return String(localized: "Like \(reference), it's \(Self.genre(genre)).", comment: "Tonight reason: shares a genre with the reference film; the genre is a noun such as 'Crime'")
        case let .referenceDecade(reference, decade):
            return String(localized: "Like \(reference), it's from the \(String(decade))s.", comment: "Tonight reason: same decade as the reference film")
        case let .requestedGenre(genre):
            return String(localized: "\(Self.genre(genre)), as you asked.", comment: "Tonight reason: the requested genre")
        }
    }

    static func rewatchLead(_ lead: TonightRewatchLead) -> String {
        switch lead {
        case let .fit(fit):
            return requestFit(fit)
        case let .sameDirector(director, verdict):
            if let rating = verdict.rating {
                return String(localized: "By \(director): you rated \(verdict.title) \(rating).", comment: "Tonight rewatch reason: another film by the same director and its rating")
            }
            if verdict.favorite {
                return String(localized: "By \(director), who also made your favorite \(verdict.title).", comment: "Tonight rewatch reason: another film by the same director is a favorite")
            }
            return String(localized: "By \(director), who also made \(verdict.title).", comment: "Tonight rewatch reason: another film by the same director")
        case let .relatedGenre(verdict, genre):
            return String(localized: "Close to \(verdict.title), which you liked; both are \(Self.genre(genre)).", comment: "Tonight rewatch reason: a similar liked film and the shared genre noun")
        case .favorite:
            return String(localized: "It's one of your favorites.", comment: "Tonight rewatch reason: a favorite film")
        case let .watchedTimes(count):
            return String(localized: "You've watched it \(count) times.", comment: "Tonight rewatch reason: number of viewings")
        case let .ownRating(rating):
            return String(localized: "You rated it \(rating).", comment: "Tonight rewatch reason: the viewer's 1-10 rating")
        case let .quickRating(rating):
            return String(localized: "You marked it as \(quick(rating)).", comment: "Tonight rewatch reason: quick verdict")
        case .fromHistory:
            return String(localized: "A film from your history.", comment: "Tonight rewatch reason: nothing more specific known")
        }
    }

    static func note(_ note: TonightNote) -> String {
        switch note {
        case .nothingMatchesRelaxServers:
            return String(localized: "Nothing matches every filter. Turn off “Only on My Servers” or loosen genre and length.", comment: "Tonight note")
        case .nothingMatchesRelaxRuntime:
            return String(localized: "Nothing matches every filter. Allow a longer runtime or remove the genre.", comment: "Tonight note")
        case .nothingMatchesRelaxGenre:
            return String(localized: "Nothing matches every filter. Remove the genre or switch between first watch and rewatch.", comment: "Tonight note")
        case .picksChangedMeanwhile:
            return String(localized: "The matching films were marked in the meantime. Choose again.", comment: "Tonight note")
        case .onlyRecentRepeats:
            return String(localized: "Every matching film was suggested recently, so some suggestions repeat.", comment: "Tonight note")
        case .someSourcesUnavailable:
            return String(localized: "Some film sources couldn't be reached; the suggestions use the rest.", comment: "Tonight note")
        case .moodMatchedByKeywords:
            return String(localized: "Your words are matched against titles, themes and synopses.", comment: "Tonight note: free text without a language model")
        }
    }
}
