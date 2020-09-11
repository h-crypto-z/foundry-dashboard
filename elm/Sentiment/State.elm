port module Sentiment.State exposing (..)

import AddressDict exposing (AddressDict)
import Common.Msg exposing (..)
import Common.Types exposing (..)
import Config
import Contracts.FryBalanceFetch
import Dict exposing (Dict)
import Eth
import Eth.Types exposing (Address)
import Eth.Utils
import Helpers.Eth as EthHelpers
import Helpers.Time as TimeHelpers
import Http
import Json.Decode exposing (Decoder)
import Json.Encode
import List.Extra
import Maybe.Extra
import Sentiment.Types exposing (..)
import Set exposing (Set)
import Task
import Time
import TokenValue exposing (TokenValue)
import Url.Builder
import UserNotice as UN
import Wallet exposing (Wallet)


init : ( Model, Cmd Msg )
init =
    ( { polls = Nothing
      , validatedResponses = Dict.empty
      , fryBalances = AddressDict.empty
      }
    , Cmd.batch
        [ fetchAllPollsCmd
        ]
    )


update : Msg -> Model -> UpdateResult
update msg prevModel =
    case msg of
        MsgUp msgUp ->
            UpdateResult
                prevModel
                Cmd.none
                [ msgUp ]

        RefreshAll ->
            UpdateResult
                prevModel
                (refreshPollVotesCmd Nothing)
                []

        PollsFetched pollsFetchedResult ->
            case pollsFetchedResult of
                Err httpErr ->
                    UpdateResult
                        prevModel
                        Cmd.none
                        [ AddUserNotice <| UN.httpFetchError "fetch polls" httpErr ]

                Ok polls ->
                    UpdateResult
                        { prevModel
                            | polls = Just polls
                        }
                        (refreshPollVotesCmd Nothing)
                        []

        OptionClicked userInfo poll pollOptionId ->
            UpdateResult
                prevModel
                (signResponseCmd userInfo poll pollOptionId)
                []

        Web3SignResultValue jsonVal ->
            let
                decodedSignResult =
                    Json.Decode.decodeValue signedResponseFromJSDecoder jsonVal
            in
            case decodedSignResult of
                Ok signResult ->
                    UpdateResult
                        prevModel
                        (sendSignedResponseCmd signResult)
                        []

                Err errStr ->
                    UpdateResult
                        prevModel
                        Cmd.none
                        [ AddUserNotice <| UN.signingError <| Json.Decode.errorToString errStr ]

        -- Web3ValidateSigResultValue jsonVal ->
        --     let
        --         decodedSignResult =
        --             Json.Decode.decodeValue validateSigResultDecoder jsonVal
        --     in
        --     case decodedSignResult of
        --         Ok validateResult ->
        --             wut
        --         Err errStr ->
        --             UpdateResult
        --                 prevModel
        --                 Cmd.none
        --                 [ AddUserNotice <| UN.unexpectedError "error decoding signature validation from web3js" errStr
        --                 ]
        ResponseSent pollId sendResult ->
            case sendResult of
                Ok _ ->
                    UpdateResult
                        prevModel
                        (refreshPollVotesCmd <| Just pollId)
                        []

                Err httpErr ->
                    UpdateResult
                        prevModel
                        Cmd.none
                        [ AddUserNotice <| UN.httpSendError "send response" httpErr ]

        SignedResponsesFetched responsesFetchedResult ->
            case responsesFetchedResult of
                Ok decodedLoggedSignedResponses ->
                    case prevModel.polls of
                        Nothing ->
                            UpdateResult
                                prevModel
                                Cmd.none
                                [ AddUserNotice <| UN.unexpectedError "Responses were fetched, but the polls haven't loaded yet!" Nothing ]

                        Just polls ->
                            let
                                ( newValidatedResponses, respondingAddresses ) =
                                    validateAndAddFetchedResponses polls decodedLoggedSignedResponses prevModel.validatedResponses

                                newBalancesDict =
                                    case respondingAddresses of
                                        [] ->
                                            prevModel.fryBalances

                                        addresses ->
                                            let
                                                newDictPortion =
                                                    addresses
                                                        |> List.map
                                                            (\address ->
                                                                ( address
                                                                , Nothing
                                                                )
                                                            )
                                                        |> AddressDict.fromList
                                            in
                                            AddressDict.union
                                                prevModel.fryBalances
                                                newDictPortion

                                cmd =
                                    newBalancesDict
                                        |> AddressDict.filter
                                            (\addressString maybeBalance ->
                                                maybeBalance == Nothing
                                            )
                                        |> AddressDict.keys
                                        |> fetchFryBalancesCmd
                            in
                            UpdateResult
                                { prevModel
                                    | validatedResponses = newValidatedResponses
                                    , fryBalances = newBalancesDict
                                }
                                cmd
                                []

                Err decodeErr ->
                    UpdateResult
                        prevModel
                        Cmd.none
                        [ AddUserNotice <| UN.unexpectedError "error decoding responses from server" decodeErr ]

        FryBalancesFetched fetchResult ->
            case fetchResult of
                Ok newFryBalances ->
                    justModelUpdate
                        { prevModel
                            | fryBalances =
                                AddressDict.union
                                    (newFryBalances
                                        |> AddressDict.map (always Just)
                                    )
                                    prevModel.fryBalances
                        }

                Err httpErr ->
                    UpdateResult
                        prevModel
                        Cmd.none
                        [ AddUserNotice <| UN.web3FetchError "fetch polls" httpErr ]


validateAndAddFetchedResponses : List Poll -> List LoggedSignedResponse -> ValidatedResponseTracker -> ( ValidatedResponseTracker, List Address )
validateAndAddFetchedResponses polls newlyFetched prevValidatedResponses =
    let
        helper : LoggedSignedResponse -> ( ValidatedResponseTracker, List Address ) -> ( ValidatedResponseTracker, List Address )
        helper loggedSignedResponse ( accValidatedResponses, accAddresses ) =
            case validateSignature polls loggedSignedResponse.signedResponse of
                Nothing ->
                    -- This means the poll Id was not found. Ignore for now.
                    ( accValidatedResponses, accAddresses )

                Just False ->
                    ( accValidatedResponses, accAddresses )

                Just True ->
                    let
                        newAccValidatedResponses =
                            let
                                maybeAlreadyExistingResponse =
                                    accValidatedResponses
                                        |> getValidatedResponse
                                            loggedSignedResponse.signedResponse.pollId
                                            loggedSignedResponse.signedResponse.address
                            in
                            case maybeAlreadyExistingResponse of
                                Nothing ->
                                    accValidatedResponses
                                        |> insertValidatedResponse
                                            loggedSignedResponse

                                Just alreadyExistingResponse ->
                                    if alreadyExistingResponse.id < loggedSignedResponse.id then
                                        accValidatedResponses
                                            |> insertValidatedResponse
                                                loggedSignedResponse

                                    else
                                        accValidatedResponses

                        newAccAddresses =
                            List.append
                                accAddresses
                                [ loggedSignedResponse.signedResponse.address ]
                    in
                    ( newAccValidatedResponses, newAccAddresses )
    in
    List.foldl helper ( prevValidatedResponses, [] ) newlyFetched
        |> Tuple.mapSecond (List.Extra.uniqueBy Eth.Utils.addressToString)


validateSignature : List Poll -> SignedResponse -> Maybe Bool
validateSignature polls signedResponse =
    let
        maybePoll =
            polls
                |> List.filter (.id >> (==) signedResponse.pollId)
                |> List.head
    in
    maybePoll
        |> Maybe.map
            (\poll ->
                let
                    sigData =
                        encodeSignableResponse
                            poll
                            signedResponse.pollOptionId
                in
                True
             --todo
             -- recover address
             -- check against address
            )


fetchAllPollsCmd : Cmd Msg
fetchAllPollsCmd =
    Http.request
        { method = "GET"
        , headers = []
        , url = "https://personal-rxyx.outsystemscloud.com/QuantumObserver/rest/VotingResults/GetPolls?FromPollId=0&Count=0"
        , body = Http.emptyBody
        , expect =
            Http.expectJson
                PollsFetched
                pollListDecoder
        , timeout = Nothing
        , tracker = Nothing
        }


pollListDecoder : Decoder (List Poll)
pollListDecoder =
    Json.Decode.list pollDecoder
        |> Json.Decode.map (List.sortBy .id)


pollDecoder : Decoder Poll
pollDecoder =
    Json.Decode.map4 Poll
        (Json.Decode.field "Id" Json.Decode.int)
        (Json.Decode.field "Title" Json.Decode.string)
        (Json.Decode.field "Question" Json.Decode.string)
        (Json.Decode.oneOf
            [ pollOptionListDecoder
            , Json.Decode.succeed []
            ]
        )


pollOptionListDecoder : Decoder (List PollOption)
pollOptionListDecoder =
    Json.Decode.field "Options" (Json.Decode.list pollOptionDecoder)
        |> Json.Decode.map (List.sortBy .id)


pollOptionDecoder : Decoder PollOption
pollOptionDecoder =
    Json.Decode.map3 PollOption
        (Json.Decode.field "Id" Json.Decode.int)
        (Json.Decode.field "PollId" Json.Decode.int)
        (Json.Decode.field "Name" Json.Decode.string)


signResponseCmd : UserInfo -> Poll -> Int -> Cmd Msg
signResponseCmd userInfo poll pollOptionId =
    web3Sign <|
        Json.Encode.object
            [ ( "data"
              , Json.Encode.string <|
                    encodeSignableResponse poll pollOptionId
              )
            , ( "address", Json.Encode.string (userInfo.address |> Eth.Utils.addressToChecksumString) )
            , ( "pollId", Json.Encode.int poll.id )
            , ( "pollOptionId", Json.Encode.int pollOptionId )
            ]


encodeSignableResponse : Poll -> Int -> String
encodeSignableResponse poll pollOptionId =
    let
        questionStr =
            poll.question

        answerStr =
            poll.options
                |> List.filter (.id >> (==) pollOptionId)
                |> List.head
                |> Maybe.map .name
                |> Maybe.withDefault ("[invalid option " ++ String.fromInt pollOptionId ++ "]")
    in
    Json.Encode.object
        [ ( "context", Json.Encode.string "FRY Holder Sentiment Voting" )
        , ( "question", Json.Encode.string questionStr )
        , ( "answer", Json.Encode.string answerStr )
        ]
        |> Json.Encode.encode 0



-- encodeSignedResponse : SignedResponse -> Json.Encode.Value
-- encodeSignedResponse signedResponse =
--     Json.Encode.object
--         [ ("address", EthHelpers.encodeAddress signedResponse.address
--         , ("pollId", Json.Encode. : Int
--         , ("pollOptionId", Json.Encode. : Int
--         , ("sig", Json.Encode. : String
--         ]


signedResponseFromJSDecoder : Json.Decode.Decoder SignedResponse
signedResponseFromJSDecoder =
    Json.Decode.map4 SignedResponse
        (Json.Decode.field "address" EthHelpers.addressDecoder)
        (Json.Decode.field "pollId" Json.Decode.int)
        (Json.Decode.field "pollOptionId" Json.Decode.int)
        (Json.Decode.field "sig" Json.Decode.string)



-- validateSigResultDecoder : Json.Decode.Decoder SigValidationResult


fetchFryBalancesCmd : List Address -> Cmd Msg
fetchFryBalancesCmd addresses =
    Contracts.FryBalanceFetch.fetch
        addresses
        FryBalancesFetched


sendSignedResponseCmd : SignedResponse -> Cmd Msg
sendSignedResponseCmd signedResponse =
    let
        url =
            Url.Builder.custom
                (Url.Builder.CrossOrigin "https://personal-rxyx.outsystemscloud.com")
                [ "QuantumObserver", "rest", "VotingResults", "PlaceVote" ]
                []
                Nothing
    in
    Http.post
        { url = url
        , body =
            Http.jsonBody <|
                encodeSignedResponseForServer signedResponse
        , expect = Http.expectWhatever (ResponseSent signedResponse.pollId)
        }


refreshPollVotesCmd : Maybe Int -> Cmd Msg
refreshPollVotesCmd maybePollId =
    let
        url =
            Url.Builder.custom
                (Url.Builder.CrossOrigin "https://personal-rxyx.outsystemscloud.com")
                [ "QuantumObserver", "rest", "VotingResults", "GetPollVotes" ]
                (case maybePollId of
                    Just pollId ->
                        [ Url.Builder.int "FromPollId" pollId
                        , Url.Builder.int "Count" 1
                        ]

                    Nothing ->
                        [ Url.Builder.int "FromPollId" 0
                        , Url.Builder.int "Count" 0
                        ]
                )
                Nothing
    in
    Http.get
        { url = url
        , expect =
            Http.expectJson
                SignedResponsesFetched
                loggedSignedResponseListFromServerDecoder
        }


loggedSignedResponseListFromServerDecoder : Json.Decode.Decoder (List LoggedSignedResponse)
loggedSignedResponseListFromServerDecoder =
    Json.Decode.list Json.Decode.value
        |> Json.Decode.map (List.map (Json.Decode.decodeValue loggedSignedResponseFromServerDecoder))
        |> Json.Decode.map (List.filterMap Result.toMaybe)


loggedSignedResponseFromServerDecoder : Json.Decode.Decoder LoggedSignedResponse
loggedSignedResponseFromServerDecoder =
    Json.Decode.field "Vote"
        (Json.Decode.map2 LoggedSignedResponse
            (Json.Decode.field "Id" Json.Decode.int)
            (Json.Decode.map4 SignedResponse
                (Json.Decode.field "Address" <| EthHelpers.addressDecoder)
                (Json.Decode.field "PollId" <| Json.Decode.int)
                (Json.Decode.field "OptionId" <| Json.Decode.int)
                (Json.Decode.field "Signature" <| Json.Decode.string)
            )
        )


encodeSignedResponseForServer : SignedResponse -> Json.Encode.Value
encodeSignedResponseForServer signedResponse =
    Json.Encode.object
        [ ( "Address", EthHelpers.encodeAddress signedResponse.address )
        , ( "PollId", Json.Encode.int signedResponse.pollId )
        , ( "OptionId", Json.Encode.int signedResponse.pollOptionId )
        , ( "Signature", Json.Encode.string signedResponse.sig )
        , ( "OptionData", Json.Encode.string "" )
        ]


subscriptions : Model -> Sub Msg
subscriptions model =
    Sub.batch
        [ Time.every 10000 <| always RefreshAll
        , web3SignResult Web3SignResultValue

        -- , web3ValidateSigResult Web3ValidateSigResultValue
        ]


port web3Sign : Json.Decode.Value -> Cmd msg


port web3SignResult : (Json.Decode.Value -> msg) -> Sub msg


port web3ValidateSig : Json.Decode.Value -> Cmd msg


port web3ValidateSigResult : (Json.Decode.Value -> msg) -> Sub msg
