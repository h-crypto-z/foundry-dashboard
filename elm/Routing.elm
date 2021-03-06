module Routing exposing (..)

import Common.Types exposing (..)
import Eth.Types exposing (Address, Hex)
import Eth.Utils
import Result.Extra
import Url exposing (Url)
import Url.Builder as Builder
import Url.Parser as Parser exposing ((</>), (<?>), Parser)
import Url.Parser.Query as Query


type Route
    = Home
    | Sentiment
    | Stats
    | Farm
    | NotFound String


routeParser : Parser (Route -> a) a
routeParser =
    Parser.oneOf
        [ Parser.map Home Parser.top
        , Parser.map Sentiment (Parser.s "sentiment")
        , Parser.map Stats (Parser.s "stats")
        , Parser.map Farm (Parser.s "farm")
        ]


routeToString : String -> Route -> String
routeToString basePath route =
    basePath
        ++ (case route of
                Home ->
                    Builder.relative
                        [ "#" ]
                        []

                Sentiment ->
                    Builder.relative
                        [ "#", "sentiment" ]
                        []
                
                Stats ->
                    Builder.relative
                        [ "#", "stats" ]
                        []
                
                Farm ->
                    Builder.relative
                        [ "#", "farm"]
                        []

                NotFound _ ->
                    Builder.relative
                        [ "#" ]
                        []
           )


urlToRoute : Url -> Route
urlToRoute url =
    Maybe.withDefault (NotFound "url not found") (Parser.parse routeParser url)
